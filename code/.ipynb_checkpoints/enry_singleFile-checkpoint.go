package main
import (
	"bytes"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"path/filepath"
    "time"
	"github.com/go-enry/go-enry/v2"
    "log"
)


func readFile(path string, limit int64) ([]byte, error) {
    
	if limit <= 0 {
		return ioutil.ReadFile(path)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	size := st.Size()
	if limit > 0 && size > limit {
		size = limit
	}
	buf := bytes.NewBuffer(nil)
	buf.Grow(int(size))
	_, err = io.Copy(buf, io.LimitReader(f, limit))
	return buf.Bytes(), err
}

func main() {
    
    start:= time.Now()
    
    fileName := os.Args[1]
    content, _ := readFile(fileName, -1)
    fmt.Println("Filename: ", fileName) 
    lang := enry.GetLanguage(filepath.Base(fileName), content)
    fmt.Println("Predicted language: ", lang)
    elapsed:= time.Since(start).Seconds()
    log.Printf("Total execution time(secs)  %f", elapsed)
}