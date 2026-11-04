// Kinoteka: copied to server/mobile/torrserverkit/kinoteka.go by build-engine.sh.
package torrserverkit

import (
	"strconv"
	"sync/atomic"
	"time"

	"server"
	"server/log"
	"server/web"
)

// relistens counts the times the web server was opened again.
var relistens int32

// Relisten opens the HTTP port of the running engine again (iOS took its socket while the app was
// suspended): port, or the same one when port <= 0. The torrents and the torrent client stay.
// Returns an empty string on success, or an error message on failure.
func Relisten(port int) string {
	runningMu.Lock()
	defer runningMu.Unlock()

	if atomic.LoadInt32(&running) == 0 {
		return "server is not running"
	}
	value := ""
	if port > 0 {
		value = strconv.Itoa(port)
	}
	if err := web.Relisten(value); err != nil {
		return err.Error()
	}
	atomic.AddInt32(&relistens, 1)
	return ""
}

// Relistens returns how many times the web server was opened again since the start.
func Relistens() int {
	return int(atomic.LoadInt32(&relistens))
}

// watchServer waits for the end of the web server (patch-server.py puts it in StartServer).
// StopServer ends it; a server that fails (iOS took its socket) is opened again, so the engine
// does not stay half-stopped and is not started a second time over the running torrent client.
func watchServer() {
	for {
		message := server.WaitServer()
		if message == "" {
			atomic.StoreInt32(&running, 0)
			return
		}
		log.TLogln("Kinoteka: the web server failed:", message)
		for attempt := 1; attempt <= 5; attempt++ {
			if web.Relisten("") == nil {
				atomic.AddInt32(&relistens, 1)
				break
			}
			time.Sleep(time.Second)
		}
	}
}

// closeFailedStart closes the torrent client left by a start that failed after connecting it:
// the next start connects a new one.
func closeFailedStart() {
	web.BTS.Disconnect()
}
