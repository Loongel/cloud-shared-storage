package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"

	"cs-storage/internal/router"
	"cs-storage/internal/routerfuse"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

func main() {
	mountpoint := flag.String("mountpoint", "", "FUSE mountpoint for the auto router")
	litefs := flag.String("litefs", "", "LiteFS backing directory")
	gluster := flag.String("gluster", "", "GlusterFS backing directory")
	classify := flag.Bool("classify", false, "read paths from stdin and print the selected engine")
	debug := flag.Bool("debug", false, "enable go-fuse debug logging")
	flag.Parse()

	if *classify {
		classifyPaths()
		return
	}
	if *mountpoint == "" || *litefs == "" || *gluster == "" {
		log.Fatal("-mountpoint, -litefs, and -gluster are required unless -classify is used")
	}
	root, err := routerfuse.NewRoot(*litefs, *gluster)
	if err != nil {
		log.Fatal(err)
	}
	server, err := fs.Mount(*mountpoint, root, &fs.Options{MountOptions: fuseMountOptions(*debug)})
	if err != nil {
		log.Fatal(err)
	}
	server.Wait()
}

func classifyPaths() {
	r := router.New()
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		path := scanner.Text()
		fmt.Printf("%s\t%s\n", r.Route(path), path)
	}
	if err := scanner.Err(); err != nil {
		log.Fatal(err)
	}
}

func fuseMountOptions(debug bool) fuse.MountOptions {
	return fuse.MountOptions{Debug: debug, AllowOther: false}
}
