//------------------------------------------------------------------------------
// <copyright file="FileEnumerator.cs" company="Microsoft">
//    Copyright (c) Microsoft Corporation
// </copyright>
//------------------------------------------------------------------------------

namespace Microsoft.Azure.Storage.DataMovement.TransferEnumerators
{
    using System;
    using System.Collections.Generic;
    using System.Diagnostics;
    using System.Globalization;
    using System.IO;
    using System.Threading;

    /// <summary>
    /// Transfer enumerator for file system.
    /// </summary>
    internal class FileHierarchyEnumerator : TransferEnumeratorBase, ITransferEnumerator
    {
        private const string DefaultFilePattern = "*";

        private DirectoryLocation location;

        private FileListContinuationToken listContinuationToken;

        private bool followSymlink;

        private string baseDirectory;

        /// <summary>
        /// Initializes a new instance of the <see cref="FileEnumerator" /> class.
        /// </summary>
        /// <param name="location">Directory location.</param>
        /// <param name="baseDirectory">Directory location.</param>
        /// <param name="followSymlink">Indicating whether to enumerate symlinked subdirectories.</param>
        public FileHierarchyEnumerator(DirectoryLocation location, string baseDirectory, bool followSymlink)
        {
            this.location = location;
            this.baseDirectory = baseDirectory;
            this.followSymlink = followSymlink;
        }

        /// <summary>
        /// Gets or sets the enumerate continulation token.
        /// </summary>
        public ListContinuationToken EnumerateContinuationToken
        {
            get
            {
                return this.listContinuationToken;
            }

            set
            {
                this.listContinuationToken = value as FileListContinuationToken;
                Debug.Assert(null == value || null != this.listContinuationToken);
            }
        }

        /// <summary>
        /// Enumerates the files present in the storage location referenced by this object.
        /// </summary>
        /// <param name="cancellationToken">CancellationToken to cancel the method.</param>
        /// <returns>Enumerable list of TransferEntry objects found in the storage location referenced by this object.</returns>
        public IEnumerable<TransferEntry> EnumerateLocation(CancellationToken cancellationToken)
        {
            Utils.CheckCancellation(cancellationToken);

            string filePattern = string.IsNullOrEmpty(this.SearchPattern) ? DefaultFilePattern : this.SearchPattern;

            SearchOption searchOption = this.Recursive ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly;
            IEnumerable<EnumerateDirectoryHelper.LocalEnumerateItem> directoryEnumerator = null;
            ErrorEntry errorEntry = null;

            Utils.CheckCancellation(cancellationToken);

            string fullPath = null;
            string baseFullPath = null;
            if (Interop.CrossPlatformHelpers.IsWindows)
            {
                fullPath = TransferManager.Configurations.SupportUncPath ?
                    LongPath.ToUncPath(this.location.DirectoryPath) :
                    LongPath.GetFullPath(this.location.DirectoryPath);
                baseFullPath = TransferManager.Configurations.SupportUncPath ?
                    LongPath.ToUncPath(this.baseDirectory) :
                    LongPath.GetFullPath(this.baseDirectory);
            }
            else
            {
                fullPath = Path.GetFullPath(this.location.DirectoryPath);
                baseFullPath = Path.GetFullPath(this.baseDirectory);
            }

            fullPath = AppendDirectorySeparator(fullPath);
            baseFullPath = AppendDirectorySeparator(baseFullPath);

            bool isBaseDirectory = string.Equals(fullPath, baseFullPath);
            try
            {
                // Directory.GetFiles/EnumerateFiles will be broken when encounted special items, such as
                // files in recycle bins or the folder "System Volume Information". Rewrite this function
                // because our listing should not be stopped by these unexpected files.
                directoryEnumerator = EnumerateDirectoryHelper.EnumerateAllEntriesInDirectory(
                    fullPath,
                    filePattern,
                    this.listContinuationToken == null ? null : this.listContinuationToken.FilePath,
                    searchOption,
                    followSymlink,
                    isBaseDirectory,
                    cancellationToken);
            }
            catch (Exception ex)
            {
                string errorMessage = string.Format(
                    CultureInfo.CurrentCulture,
                    Resources.FailedToEnumerateDirectory,
                    this.location.DirectoryPath,
                    filePattern);

                TransferException exception =
                    new TransferException(TransferErrorCode.FailToEnumerateDirectory, errorMessage, ex);
                errorEntry = new ErrorEntry(exception);
            }

            if (null != errorEntry)
            {
                // We any exception we might get from Directory.GetFiles/
                // Directory.EnumerateFiles. Just return an error entry
                // to indicate error occured in this case. 
                yield return errorEntry;
            }

            if (null != directoryEnumerator)
            {
                foreach (var entry in directoryEnumerator)
                {
                    Utils.CheckCancellation(cancellationToken);

                    string relativePath = entry.Path;

                    if (relativePath.StartsWith(baseFullPath, StringComparison.OrdinalIgnoreCase))
                    {
                        relativePath = relativePath.Remove(0, baseFullPath.Length);
                    }

                    string continuationTokenPath = entry.Path;
                    continuationTokenPath = continuationTokenPath.Remove(0, fullPath.Length);
                    var continuationToken = new FileListContinuationToken(continuationTokenPath);

                    if (relativePath.Length > Constants.MaxRelativePathLength)
                    {
                        relativePath = relativePath.Substring(0, Constants.MaxRelativePathLength / 2) + "..." + relativePath.Substring(relativePath.Length - Constants.MaxRelativePathLength / 2);
                    }

                    if (entry.IsDirectory)
                    {
                        yield return new DirectoryEntry(
                            relativePath,
                            LongPath.Combine(this.baseDirectory, relativePath),
                            continuationToken);
                    }
                    else
                    {
                        yield return new FileEntry(
                            relativePath,
                            LongPath.Combine(this.baseDirectory, relativePath),
                            continuationToken);
                    }
                }
            }
        }

        private static string AppendDirectorySeparator(string dir)
        {
            char lastC = dir[dir.Length - 1];
            if (Path.DirectorySeparatorChar != lastC && Path.AltDirectorySeparatorChar != lastC)
            {
                dir = dir + Path.DirectorySeparatorChar;
            }

            return dir;
        }
    }
}
