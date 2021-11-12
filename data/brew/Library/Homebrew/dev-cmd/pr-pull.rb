# typed: false
# frozen_string_literal: true

require "download_strategy"
require "cli/parser"
require "utils/github"
require "tmpdir"
require "formula"

module Homebrew
  extend T::Sig

  module_function

  sig { returns(CLI::Parser) }
  def pr_pull_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Download and publish bottles, and apply the bottle commit from a
        pull request with artifacts generated by GitHub Actions.
        Requires write access to the repository.
      EOS
      switch "--no-upload",
             description: "Download the bottles but don't upload them."
      switch "--no-commit",
             description: "Do not generate a new commit before uploading."
      switch "-n", "--dry-run",
             description: "Print what would be done rather than doing it."
      switch "--clean",
             description: "Do not amend the commits from pull requests."
      switch "--keep-old",
             description: "If the formula specifies a rebuild version, " \
                          "attempt to preserve its value in the generated DSL."
      switch "--autosquash",
             description: "Automatically reformat and reword commits in the pull request to our "\
                          "preferred format."
      switch "--branch-okay",
             description: "Do not warn if pulling to a branch besides the repository default (useful for testing)."
      switch "--resolve",
             description: "When a patch fails to apply, leave in progress and allow user to resolve, "\
                          "instead of aborting."
      switch "--warn-on-upload-failure",
             description: "Warn instead of raising an error if the bottle upload fails. "\
                          "Useful for repairing bottle uploads that previously failed."
      flag   "--committer=",
             description: "Specify a committer name and email in `git`'s standard author format."
      flag   "--message=",
             depends_on:  "--autosquash",
             description: "Message to include when autosquashing revision bumps, deletions, and rebuilds."
      flag   "--artifact=",
             description: "Download artifacts with the specified name (default: `bottles`)."
      flag   "--tap=",
             description: "Target tap repository (default: `homebrew/core`)."
      flag   "--root-url=",
             description: "Use the specified <URL> as the root of the bottle's URL instead of Homebrew's default."
      flag   "--root-url-using=",
             description: "Use the specified download strategy class for downloading the bottle's URL instead of "\
                          "Homebrew's default."
      comma_array "--workflows=",
                  description: "Retrieve artifacts from the specified workflow (default: `tests.yml`). "\
                               "Can be a comma-separated list to include multiple workflows."
      comma_array "--ignore-missing-artifacts=",
                  description: "Comma-separated list of workflows which can be ignored if they have not been run."

      conflicts "--clean", "--autosquash"

      named_args :pull_request, min: 1
    end
  end

  # Separates a commit message into subject, body, and trailers.
  def separate_commit_message(message)
    subject = message.lines.first.strip

    # Skip the subject and separate lines that look like trailers (e.g. "Co-authored-by")
    # from lines that look like regular body text.
    trailers, body = message.lines.drop(1).partition { |s| s.match?(/^[a-z-]+-by:/i) }

    trailers = trailers.uniq.join.strip
    body = body.join.strip.gsub(/\n{3,}/, "\n\n")

    [subject, body, trailers]
  end

  def signoff!(path, pr: nil, dry_run: false)
    subject, body, trailers = separate_commit_message(path.git_commit_message)

    if pr
      # This is a tap pull request and approving reviewers should also sign-off.
      tap = Tap.from_path(path)
      review_trailers = GitHub.approved_reviews(tap.user, tap.full_name.split("/").last, pr).map do |r|
        "Signed-off-by: #{r["name"]} <#{r["email"]}>"
      end
      trailers = trailers.lines.concat(review_trailers).map(&:strip).uniq.join("\n")

      # Append the close message as well, unless the commit body already includes it.
      close_message = "Closes ##{pr}."
      body += "\n\n#{close_message}" unless body.include? close_message
    end

    git_args = Utils::Git.git, "-C", path, "commit", "--amend", "--signoff", "--allow-empty", "--quiet",
               "--message", subject, "--message", body, "--message", trailers

    if dry_run
      puts(*git_args)
    else
      safe_system(*git_args)
    end
  end

  def determine_bump_subject(old_contents, new_contents, formula_path, reason: nil)
    formula_path = Pathname(formula_path)
    formula_name = formula_path.basename.to_s.chomp(".rb")

    new_formula = begin
      Formulary.from_contents(formula_name, formula_path, new_contents, :stable)
    rescue FormulaUnavailableError
      nil
    end

    return "#{formula_name}: delete #{reason}".strip if new_formula.blank?

    old_formula = begin
      Formulary.from_contents(formula_name, formula_path, old_contents, :stable)
    rescue FormulaUnavailableError
      nil
    end

    return "#{formula_name} #{new_formula.stable.version} (new formula)" if old_formula.blank?

    if old_formula.stable.version != new_formula.stable.version
      "#{formula_name} #{new_formula.stable.version}"
    elsif old_formula.revision != new_formula.revision
      "#{formula_name}: revision #{reason}".strip
    else
      "#{formula_name}: #{reason || "rebuild"}".strip
    end
  end

  # Cherry picks a single commit that modifies a single file.
  # Potentially rewords this commit using {determine_bump_subject}.
  def reword_formula_commit(commit, file, reason: "", verbose: false, resolve: false, path: ".")
    formula_file = Pathname.new(path) / file
    formula_name = formula_file.basename.to_s.chomp(".rb")

    odebug "Cherry-picking #{formula_file}: #{commit}"
    Utils::Git.cherry_pick!(path, commit, verbose: verbose, resolve: resolve)

    old_formula = Utils::Git.file_at_commit(path, file, "HEAD^")
    new_formula = Utils::Git.file_at_commit(path, file, "HEAD")

    bump_subject = determine_bump_subject(old_formula, new_formula, formula_file, reason: reason).strip
    subject, body, trailers = separate_commit_message(path.git_commit_message)

    if subject != bump_subject && !subject.start_with?("#{formula_name}:")
      safe_system("git", "-C", path, "commit", "--amend", "-q",
                  "-m", bump_subject, "-m", subject, "-m", body, "-m", trailers)
      ohai bump_subject
    else
      ohai subject
    end
  end

  # Cherry picks multiple commits that each modify a single file.
  # Words the commit according to {determine_bump_subject} with the body
  # corresponding to all the original commit messages combined.
  def squash_formula_commits(commits, file, reason: "", verbose: false, resolve: false, path: ".")
    odebug "Squashing #{file}: #{commits.join " "}"

    # Format commit messages into something similar to `git fmt-merge-message`.
    # * subject 1
    # * subject 2
    #   optional body
    # * subject 3
    messages = []
    trailers = []
    commits.each do |commit|
      subject, body, trailer = separate_commit_message(path.git_commit_message(commit))
      body = body.lines.map { |line| "  #{line.strip}" }.join("\n")
      messages << "* #{subject}\n#{body}".strip
      trailers << trailer
    end

    # Get the set of authors in this series.
    authors = Utils.safe_popen_read("git", "-C", path, "show",
                                    "--no-patch", "--pretty=%an <%ae>", *commits).lines.map(&:strip).uniq.compact

    # Get the author and date of the first commit of this series, which we use for the squashed commit.
    original_author = authors.shift
    original_date = Utils.safe_popen_read "git", "-C", path, "show", "--no-patch", "--pretty=%ad", commits.first

    # Generate trailers for coauthors and combine them with the existing trailers.
    co_author_trailers = authors.map { |au| "Co-authored-by: #{au}" }
    trailers = [trailers + co_author_trailers].flatten.uniq.compact

    # Apply the patch series but don't commit anything yet.
    Utils::Git.cherry_pick!(path, "--no-commit", *commits, verbose: verbose, resolve: resolve)

    # Determine the bump subject by comparing the original state of the tree to its current state.
    formula_file = Pathname.new(path) / file
    old_formula = Utils::Git.file_at_commit(path, file, "#{commits.first}^")
    new_formula = File.read(formula_file)
    bump_subject = determine_bump_subject(old_formula, new_formula, formula_file, reason: reason)

    # Commit with the new subject, body, and trailers.
    safe_system("git", "-C", path, "commit", "--quiet",
                "-m", bump_subject, "-m", messages.join("\n"), "-m", trailers.join("\n"),
                "--author", original_author, "--date", original_date, "--", file)
    ohai bump_subject
  end

  def autosquash!(original_commit, path: ".", reason: "", verbose: false, resolve: false)
    path = Pathname(path).extend(GitRepositoryExtension)
    original_head = path.git_head

    commits = Utils.safe_popen_read("git", "-C", path, "rev-list",
                                    "--reverse", "#{original_commit}..HEAD").lines.map(&:strip)

    # Generate a bidirectional mapping of commits <=> formula files.
    files_to_commits = {}
    commits_to_files = commits.map do |commit|
      files = Utils.safe_popen_read("git", "-C", path, "diff-tree", "--diff-filter=AMD",
                                    "-r", "--name-only", "#{commit}^", commit).lines.map(&:strip)
      files.each do |file|
        files_to_commits[file] ||= []
        files_to_commits[file] << commit
        next if %r{^Formula/.*\.rb$}.match?(file)

        odie <<~EOS
          Autosquash can't squash commits that modify non-formula files.
            File:   #{file}
            Commit: #{commit}
        EOS
      end
      [commit, files]
    end.to_h

    # Reset to state before cherry-picking.
    safe_system "git", "-C", path, "reset", "--hard", original_commit

    # Iterate over every commit in the pull request series, but if we have to squash
    # multiple commits into one, ensure that we skip over commits we've already squashed.
    processed_commits = []
    commits.each do |commit|
      next if processed_commits.include? commit

      files = commits_to_files[commit]
      if files.length == 1 && files_to_commits[files.first].length == 1
        # If there's a 1:1 mapping of commits to files, just cherry pick and (maybe) reword.
        reword_formula_commit(commit, files.first, path: path, reason: reason, verbose: verbose, resolve: resolve)
        processed_commits << commit
      elsif files.length == 1 && files_to_commits[files.first].length > 1
        # If multiple commits modify a single file, squash them down into a single commit.
        file = files.first
        commits = files_to_commits[file]
        squash_formula_commits(commits, file, path: path, reason: reason, verbose: verbose, resolve: resolve)
        processed_commits += commits
      else
        # We can't split commits (yet) so just raise an error.
        odie <<~EOS
          Autosquash can't split commits that modify multiple files.
            Commit: #{commit}
            Files:  #{files.join " "}
        EOS
      end
    end
  rescue
    opoo "Autosquash encountered an error; resetting to original cherry-picked state at #{original_head}"
    system "git", "-C", path, "reset", "--hard", original_head
    system "git", "-C", path, "cherry-pick", "--abort"
    raise
  end

  def cherry_pick_pr!(user, repo, pr, args:, path: ".")
    if args.dry_run?
      puts <<~EOS
        git fetch --force origin +refs/pull/#{pr}/head
        git merge-base HEAD FETCH_HEAD
        git cherry-pick --ff --allow-empty $merge_base..FETCH_HEAD
      EOS
      return
    end

    commits = GitHub.pull_request_commits(user, repo, pr)
    safe_system "git", "-C", path, "fetch", "--quiet", "--force", "origin", commits.last
    ohai "Using #{commits.count} commit#{"s" unless commits.count == 1} from ##{pr}"
    Utils::Git.cherry_pick!(path, "--ff", "--allow-empty", *commits, verbose: args.verbose?, resolve: args.resolve?)
  end

  def formulae_need_bottles?(tap, original_commit, user, repo, pr, args:)
    return if args.dry_run?

    labels = GitHub.pull_request_labels(user, repo, pr)

    return false if labels.include?("CI-syntax-only") || labels.include?("CI-no-bottles")

    changed_formulae(tap, original_commit).any? do |f|
      !f.bottle_unneeded? && !f.bottle_disabled?
    end
  end

  def changed_formulae(tap, original_commit)
    if Homebrew::EnvConfig.disable_load_formula?
      opoo "Can't check if updated bottles are necessary as formula loading is disabled!"
      return
    end

    Utils.popen_read("git", "-C", tap.path, "diff-tree",
                     "-r", "--name-only", "--diff-filter=AM",
                     original_commit, "HEAD", "--", tap.formula_dir)
         .lines
         .map do |line|
      next unless line.end_with? ".rb\n"

      name = "#{tap.name}/#{File.basename(line.chomp, ".rb")}"
      Formula[name]
    end.compact
  end

  def download_artifact(url, dir, pr)
    odie "Credentials must be set to access the Artifacts API" if GitHub::API.credentials_type == :none

    token = GitHub::API.credentials
    curl_args = ["--header", "Authorization: token #{token}"]

    # Download the artifact as a zip file and unpack it into `dir`. This is
    # preferred over system `curl` and `tar` as this leverages the Homebrew
    # cache to avoid repeated downloads of (possibly large) bottles.
    FileUtils.chdir dir do
      downloader = GitHubArtifactDownloadStrategy.new(url, "artifact", pr, curl_args: curl_args, secrets: [token])
      downloader.fetch
      downloader.stage
    end
  end

  def pr_pull
    args = pr_pull_args.parse

    workflows = args.workflows.presence || ["tests.yml"]
    artifact = args.artifact || "bottles"
    tap = Tap.fetch(args.tap || CoreTap.instance.name)

    Utils::Git.set_name_email!(committer: args.committer.blank?)
    Utils::Git.setup_gpg!

    if (committer = args.committer)
      committer = Utils.parse_author!(committer)
      ENV["GIT_COMMITTER_NAME"] = committer[:name]
      ENV["GIT_COMMITTER_EMAIL"] = committer[:email]
    end

    args.named.uniq.each do |arg|
      arg = "#{tap.default_remote}/pull/#{arg}" if arg.to_i.positive?
      url_match = arg.match HOMEBREW_PULL_OR_COMMIT_URL_REGEX
      _, user, repo, pr = *url_match
      odie "Not a GitHub pull request: #{arg}" unless pr

      if !tap.path.git_default_origin_branch? || args.branch_okay? || args.clean?
        opoo "Current branch is #{tap.path.git_branch}: do you need to pull inside #{tap.path.git_origin_branch}?"
      end

      ohai "Fetching #{tap} pull request ##{pr}"
      Dir.mktmpdir pr do |dir|
        cd dir do
          original_commit = ENV["GITHUB_SHA"].presence || tap.path.git_head

          unless args.no_commit?
            cherry_pick_pr!(user, repo, pr, path: tap.path, args: args)
            if args.autosquash? && !args.dry_run?
              autosquash!(original_commit, path: tap.path,
                          verbose: args.verbose?, resolve: args.resolve?, reason: args.message)
            end
            signoff!(tap.path, pr: pr, dry_run: args.dry_run?) unless args.clean?
          end

          unless formulae_need_bottles?(tap, original_commit, user, repo, pr, args: args)
            ohai "Skipping artifacts for ##{pr} as the formulae don't need bottles"
            next
          end

          workflows.each do |workflow|
            workflow_run = GitHub.get_workflow_run(
              user, repo, pr, workflow_id: workflow, artifact_name: artifact
            )
            if args.ignore_missing_artifacts.present? &&
               args.ignore_missing_artifacts.include?(workflow) &&
               workflow_run.first.blank?
              # Ignore that workflow as it was not executed and we specified
              # that we could skip it.
              ohai "Ignoring workflow #{workflow} as requested by `--ignore-missing-artifacts`"
              next
            end

            ohai "Downloading bottles for workflow: #{workflow}"
            url = GitHub.get_artifact_url(workflow_run)
            download_artifact(url, dir, pr)
          end

          next if args.no_upload?

          upload_args = ["pr-upload"]
          upload_args << "--debug" if args.debug?
          upload_args << "--verbose" if args.verbose?
          upload_args << "--no-commit" if args.no_commit?
          upload_args << "--dry-run" if args.dry_run?
          upload_args << "--keep-old" if args.keep_old?
          upload_args << "--warn-on-upload-failure" if args.warn_on_upload_failure?
          upload_args << "--committer=#{args.committer}" if args.committer
          upload_args << "--root-url=#{args.root_url}" if args.root_url
          upload_args << "--root-url-using=#{args.root_url_using}" if args.root_url_using
          safe_system HOMEBREW_BREW_FILE, *upload_args
        end
      end
    end
  end
end

class GitHubArtifactDownloadStrategy < AbstractFileDownloadStrategy
  extend T::Sig

  def fetch(timeout: nil)
    ohai "Downloading #{url}"
    if cached_location.exist?
      puts "Already downloaded: #{cached_location}"
    else
      begin
        curl "--location", "--create-dirs", "--output", temporary_path, url,
             *meta.fetch(:curl_args, []),
             secrets: meta.fetch(:secrets, []),
             timeout: timeout
      rescue ErrorDuringExecution
        raise CurlDownloadStrategyError, url
      end
      ignore_interrupts do
        cached_location.dirname.mkpath
        temporary_path.rename(cached_location)
        symlink_location.dirname.mkpath
      end
    end
    FileUtils.ln_s cached_location.relative_path_from(symlink_location.dirname), symlink_location, force: true
  end

  private

  sig { returns(String) }
  def resolved_basename
    "artifact.zip"
  end
end
