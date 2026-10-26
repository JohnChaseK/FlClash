//go:build ios

package core

import (
	t "core/tun"
	"encoding/json"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/listener/sing_tun"
)

var (
	appleEvents     = make(chan []byte, 1)
	appleEventLease atomic.Int64
	appleTunMu      sync.Mutex
	appleTun        *sing_tun.Listener
)

func init() {
	// Packet tunnel extensions have a much smaller memory allowance than apps.
	debug.SetGCPercent(20)
	debug.SetMemoryLimit(40 * 1024 * 1024)
}

func AppleInvokeMethod(data string, reply func([]byte)) {
	call := &MethodCall{}
	if err := json.Unmarshal([]byte(data), call); err != nil {
		reply(encodeResponse(MethodResponse{Error: &MethodError{
			Code: "invalid_method_call", Message: err.Error(),
		}}))
		return
	}
	dispatchMethodCall(call, reply)
}

func hasEventListener() bool {
	return time.Now().UnixNano() < appleEventLease.Load()
}

func deliverEvent(data []byte) {
	// Backpressure stays in the shared class-specific queues. A suspended host
	// expires its lease instead of growing a second native event backlog.
	timer := time.NewTimer(time.Until(time.Unix(0, appleEventLease.Load())))
	defer timer.Stop()
	select {
	case appleEvents <- data:
	case <-timer.C:
	}
}

func ApplePollEvent() []byte {
	appleEventLease.Store(time.Now().Add(3 * time.Second).UnixNano())
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	select {
	case data := <-appleEvents:
		return data
	case <-timer.C:
		return nil
	}
}

func AppleSuspendEvents() {
	appleEventLease.Store(0)
	stopRouteWatch()
	select {
	case <-appleEvents:
	default:
	}
}

func AppleStartTun(fd int, stack, address, dns, options string) bool {
	appleTunMu.Lock()
	defer appleTunMu.Unlock()
	if appleTun != nil {
		_ = appleTun.Close()
		appleTun = nil
	}
	configMu.Lock()
	appleTun = t.Start(fd, stack, address, dns, options)
	configMu.Unlock()
	if appleTun == nil {
		return false
	}
	handleStartListener()
	bumpRouteEpoch()
	return true
}

func AppleStopTun() {
	appleTunMu.Lock()
	defer appleTunMu.Unlock()
	if appleTun != nil {
		_ = appleTun.Close()
		appleTun = nil
	}
	handleStopListener()
}
