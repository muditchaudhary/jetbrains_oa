package main
import (
	"fmt"
    "time"
    "os"
	"github.com/go-enry/go-enry/v2"
    "log"
)


func main() {
    
    start:= time.Now()
    
    fileName := os.Args[1]
    //content, _ := readFile(fileName, -1)
    fmt.Println("Filename: ", fileName) 
    config := enry.IsConfiguration(fileName)
    fmt.Println("Is Config? ",config)
    doc := enry.IsDocumentation(fileName)
    fmt.Println("Is Documentation? ", doc)
    elapsed:= time.Since(start).Seconds()
    log.Printf("Total execution time(secs)  %f", elapsed)
}