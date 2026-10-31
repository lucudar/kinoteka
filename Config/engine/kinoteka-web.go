// Kinoteka: copied to server/web/kinoteka.go by build-engine.sh.
//
// iOS takes the sockets of a suspended app (mostly while the iPhone is locked). A listening socket
// taken this way accepts nothing any more and reports no error: the engine stays "running", but
// every request to it hangs until the app is closed. Relisten closes the web servers and opens
// their ports again with the same routes, without restarting the engine.
package web

import (
	"errors"
	"net/http"
	"sync"

	"server/log"
	"server/settings"
)

var (
	kinotekaMu      sync.Mutex
	kinotekaHandler http.Handler
)

// kinotekaKeep is called by Start (patch-server.py) with the routes it serves.
func kinotekaKeep(h http.Handler) {
	kinotekaMu.Lock()
	kinotekaHandler = h
	kinotekaMu.Unlock()
}

// Relisten closes the web servers and starts them again: on the same HTTP port, or on port when
// it is not empty.
func Relisten(port string) error {
	kinotekaMu.Lock()
	defer kinotekaMu.Unlock()
	if kinotekaHandler == nil {
		return errors.New("the web server is not started")
	}
	if stopRenew != nil {
		close(stopRenew)
		stopRenew = nil
	}
	shutdownServers()
	previous := settings.Port
	if port != "" {
		kinotekaSetPort(port)
	}
	if err := startServers(kinotekaHandler); err != nil {
		log.TLogln("Kinoteka: the web server is not opened again:", err)
		// The next attempt without a port tries the one that worked.
		kinotekaSetPort(previous)
		return err
	}
	log.TLogln("Kinoteka: the web server is opened again, port", settings.Port)
	return nil
}

func kinotekaSetPort(port string) {
	settings.Port = port
	if settings.Args != nil {
		settings.Args.Port = port
	}
}
