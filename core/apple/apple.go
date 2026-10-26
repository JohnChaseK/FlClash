//go:build ios

package apple

import "core"

type ResultHandler interface {
	OnResult(data []byte) error
}

func InvokeMethod(data string, handler ResultHandler) {
	core.AppleInvokeMethod(data, func(result []byte) {
		_ = handler.OnResult(result)
	})
}

func PollEvent() []byte {
	return core.ApplePollEvent()
}

func SuspendEvents() {
	core.AppleSuspendEvents()
}

func StartTun(fd int32, stack, address, dns, options string) bool {
	return core.AppleStartTun(int(fd), stack, address, dns, options)
}

func StopTun() {
	core.AppleStopTun()
}
