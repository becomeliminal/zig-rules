// Command stdlib uses cgo only through the standard library: net's resolver
// and os/user, as most Go services do. Importing them links their cgo; the
// test only needs the binary to link and run, so nothing is looked up.
package main

import (
	"fmt"
	"net"
	"os/user"
)

var (
	_ = net.LookupHost
	_ = user.Current
)

func main() {
	fmt.Println("net and os/user: ok")
}
