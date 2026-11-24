#Requires AutoHotkey v2.0
#Include MediaSeek.ahk

checks := 0
try {
    AssertEqual(MediaTarget(95e7, [10, -1], 0, 100e7), 99e7, "ordered upper clamp")
    AssertEqual(MediaTarget(5e7, [-10, 1], 0, 100e7), 1e7, "ordered lower clamp")
    AssertEqual(MediaTarget(20e7, [-100], 10e7, 100e7), 10e7, "nonzero lower bound")
    AssertEqual(MediaFormatTime(65e7), "1:05", "minute display")
    AssertEqual(MediaFormatTime(3661e7), "1:01:01", "hour display")

    api := FakeMediaApi()
    controller := NewController(api)
    Loop 20 {
        controller.Pending.Push(1)
        controller.Update((A_Index - 1) * 50)
    }
    controller.Update(1100)
    AssertEqual(api.Targets[api.Targets.Length], 20e7, "20 inputs retain 20 seconds")
    AssertEqual(api.Targets.Length <= 11, true, "100ms send rate limit")
    AssertEqual(controller.Pending.Length, 0, "trailing inputs flushed")

    api := FakeMediaApi(50e7)
    api.Hold := true
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    controller.Pending.Push(1, 1)
    controller.Update(200)
    AssertEqual(api.Targets.Length, 1, "one in-flight operation")
    AssertEqual(controller.Pending.Length, 2, "inputs retained while busy")
    controller.Operation.Pending := false
    controller.Update(300)
    AssertEqual(api.Targets[2], 53e7, "inputs accumulated after completion")

    api := FakeMediaApi(50e7)
    api.Hold := true
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    controller.Pending.Push(1, 1)
    controller.Update(600)
    controller.Operation.Pending := false
    controller.Update(700)
    AssertEqual(api.Targets[2], 53e7, "slow seek retains accumulated target")

    for boundary in [0, 100e7] {
        api := FakeMediaApi(boundary)
        controller := NewController(api)
        controller.Pending.Push(boundary = 0 ? -10 : 10)
        controller.Update(0)
        AssertEqual(api.Targets.Length, 0, "already at boundary")
    }

    for direction in [-1, 1] {
        api := FakeMediaApi(50e7)
        controller := NewController(api)
        controller.Pending.Push(direction * 100)
        controller.Update(0)
        Loop 5 {
            controller.Pending.Push(direction * 100)
            controller.Update(A_Index * 100)
        }
        AssertEqual(api.Targets.Length, 1, "stale timeline boundary duplicates omitted")
        controller.Pending.Push(direction * 100)
        controller.Update(2000)
        AssertEqual(api.Targets.Length, 1, "boundary duplicate omitted after idle")
        controller.Pending.Push(-direction)
        controller.Update(2100)
        AssertEqual(api.Targets[2], direction = 1 ? 99e7 : 1e7,
            "reverse from boundary uses target despite stale timeline")
    }

    api := FakeMediaApi(50e7)
    controller := NewController(api)
    Loop 20 {
        controller.Pending.Push(10)
        controller.Update((A_Index - 1) * 100)
    }
    AssertEqual(api.Targets.Length, 5, "long repeat at end never seeks backward")

    api := FakeMediaApi(50e7)
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    api.Snapshot.Updated := 2
    api.Snapshot.Position := 10e7
    controller.Pending.Push(1)
    controller.Update(100)
    AssertEqual(api.Targets[2], 11e7, "updated player timeline resynchronizes")
    api.Snapshot.SessionKey := 2
    api.Snapshot.Position := 30e7
    controller.Pending.Push(1)
    controller.Update(200)
    AssertEqual(api.Targets[3], 31e7, "session switch resets target")

    api := FakeMediaApi(50e7)
    api.Snapshot.Rate := 2.0
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    controller.Pending.Push(1)
    controller.Update(controller.Last.At + 100)
    AssertEqual(api.Targets[2], 52.2e7, "playing position accounts for playback rate")

    api := FakeMediaApi(50e7)
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    controller.Operation.Success := false
    controller.Pending.Push(1)
    controller.Update(100)
    AssertEqual(api.Targets[2], 51e7, "failed seek does not advance cached target")

    api := FakeMediaApi()
    api.Snapshot := 0
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    AssertEqual(api.Targets.Length, 0, "unsupported session is a no-op")
    AssertEqual(controller.Pending.Length, 0, "unsupported inputs do not replay later")

    api := FakeMediaApi(50e7)
    api.Hold := true
    controller := NewController(api)
    controller.Pending.Push(1)
    controller.Update(0)
    controller.LastSentAt := A_TickCount - controller.Settings.TimeoutMs - 1
    controller.Tick()
    Critical("Off")
    AssertEqual(api.Canceled, true, "timeout cancels operation")
    AssertEqual(controller.Operation, 0, "timeout clears operation")
    AssertEqual(controller.Last, 0, "timeout clears target")
    AssertEqual(controller.Running, false, "idle timer stops after timeout")

    ; Exercise real timer scheduling with a fake API: no media is changed.
    api := FakeMediaApi(50e7)
    controller := NewController(api)
    controller.Enqueue(1)
    Sleep(150)
    AssertEqual(api.Targets.Length, 1, "Enqueue starts worker timer")
    AssertEqual(controller.Running, false, "worker stops when idle")

    if A_Args.Length && A_Args[1] = "--live-read" {
        snapshot := MediaApi(5000).ReadSnapshot()
        FileAppend(snapshot ? "Read-only media snapshot: " snapshot.App "`n"
            : "Read-only media snapshot: no seekable session`n", "*")
    }
    FileAppend("PASS: " checks " checks`n", "*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n", "*")
    ExitApp(1)
}

AssertEqual(actual, expected, label) {
    global checks
    checks += 1
    if actual != expected
        throw Error(label ": expected " expected ", got " actual)
}

NewController(api) {
    return MediaSeeker({SendIntervalMs: 100, TimeoutMs: 1500,
        ShowPosition: false, PositionDisplayMs: 800}, api)
}

class FakeMediaApi {
    __New(position := 0) {
        this.Snapshot := {Session: 1, SessionKey: 1, App: "Test player",
            Position: position, Updated: 1, Minimum: 0, Maximum: 100e7, Rate: 0}
        this.Targets := []
        this.Hold := false
        this.Canceled := false
    }
    ReadSnapshot() => this.Snapshot
    BeginSeek(session, target) {
        this.Targets.Push(target)
        return {Pending: this.Hold, Success: true}
    }
    IsPending(operation) => operation.Pending
    SeekResult(operation) => operation.Success
    Cancel(operation) => this.Canceled := true
    Reset() => 0
}
