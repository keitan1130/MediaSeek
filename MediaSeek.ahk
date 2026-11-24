#Requires AutoHotkey v2.0
#SingleInstance Force

; User settings: seconds and milliseconds.
MediaSeekSettings := {
    LargeSeconds: 10,
    SmallSeconds: 1,
    SendIntervalMs: 100,
    TimeoutMs: 1500,
    ShowPosition: true,
    PositionDisplayMs: 800
}

if A_LineFile = A_ScriptFullPath {
    seeker := MediaSeeker(MediaSeekSettings, MediaApi(MediaSeekSettings.TimeoutMs))
    Hotkey("^!+F7", (*) => seeker.Enqueue(-MediaSeekSettings.LargeSeconds))
    Hotkey("^!+F8", (*) => seeker.Enqueue(MediaSeekSettings.LargeSeconds))
    Hotkey("^!+F9", (*) => seeker.Enqueue(-MediaSeekSettings.SmallSeconds))
    Hotkey("^!+F10", (*) => seeker.Enqueue(MediaSeekSettings.SmallSeconds))
}

class MediaSeeker {
    __New(settings, api) {
        if settings.SendIntervalMs < 1 || settings.TimeoutMs < 1
            || settings.PositionDisplayMs < 1
            throw ValueError("Intervals must be positive milliseconds")
        this.Settings := settings
        this.Api := api
        this.Pending := []
        this.Operation := 0
        this.Last := 0
        this.LastSentAt := -settings.SendIntervalMs
        this.Running := false
        this.Busy := false
        this.Timer := ObjBindMethod(this, "Tick")
    }

    Enqueue(seconds) {
        ; Only queue manipulation is critical; no COM calls or waits here.
        previousCritical := Critical()
        this.Pending.Push(seconds)
        if !this.Running {
            this.Running := true
            SetTimer(this.Timer, 15)
        }
        Critical(previousCritical)
        if this.Settings.ShowPosition && this.Last
            && (this.Operation || A_TickCount - this.Last.At <= 500) {
            position := this.Last.Target + (A_TickCount - this.Last.At) * 10000 * this.Last.Rate
            position := MediaClamp(position, this.Last.Minimum, this.Last.Maximum)
            target := MediaTarget(position, this.Pending, this.Last.Minimum, this.Last.Maximum)
            MediaShowPosition(this.Last.App, target, this.Last.Maximum, this.Settings.PositionDisplayMs)
        }
    }

    Tick() {
        if this.Busy
            return
        this.Busy := true
        try {
            this.Update(A_TickCount)
        } catch {
            if this.Operation {
                try this.Api.Cancel(this.Operation)
            }
            this.Operation := 0
            this.Last := 0
            this.Pending := []
            this.Api.Reset()
            if this.Settings.ShowPosition
                ToolTip()
        } finally {
            ; Do not race an Enqueue while stopping the timer.
            Critical
            this.Busy := false
            if !this.Pending.Length && !this.Operation {
                SetTimer(this.Timer, 0)
                this.Running := false
            }
        }
    }

    Update(now) {
        if this.Operation {
            if this.Api.IsPending(this.Operation) {
                if now - this.LastSentAt >= this.Settings.TimeoutMs
                    throw Error("Media operation timed out")
                return
            }
            succeeded := this.Api.SeekResult(this.Operation)
            this.Operation := 0
            if !succeeded {
                this.Last := 0
                if this.Settings.ShowPosition
                    ToolTip()
            }
        }
        if !this.Pending.Length || now - this.LastSentAt < this.Settings.SendIntervalMs
            return

        readStarted := A_TickCount
        snapshot := this.Api.ReadSnapshot()
        now += A_TickCount - readStarted
        ; ReadSnapshot can yield during first-time manager initialization.
        Critical
        inputs := this.Pending
        this.Pending := []
        Critical("Off")
        if !snapshot {
            this.Last := 0
            return
        }

        ; Until the player publishes a new timeline, its position may still
        ; predate our successful seek. Keep accumulating from our own target.
        sameTimeline := this.Last
            && this.Last.SessionKey = snapshot.SessionKey
            && this.Last.Updated = snapshot.Updated
            && this.Last.Minimum = snapshot.Minimum && this.Last.Maximum = snapshot.Maximum
        position := sameTimeline
            ? this.Last.Target + (now - this.Last.At) * 10000 * snapshot.Rate
            : snapshot.Position
        position := MediaClamp(position, snapshot.Minimum, snapshot.Maximum)
        target := MediaTarget(position, inputs, snapshot.Minimum, snapshot.Maximum)

        if this.Settings.ShowPosition
            MediaShowPosition(snapshot.App, target, snapshot.Maximum, this.Settings.PositionDisplayMs)

        ; Skip unchanged positions, including repeated requests at either boundary
        ; while the player is still publishing the pre-seek timeline.
        duplicateBoundary := sameTimeline && target = this.Last.Target
            && (target = snapshot.Minimum || target = snapshot.Maximum)
        if target = Round(position) || duplicateBoundary
            return

        this.Operation := this.Api.BeginSeek(snapshot.Session, target)
        this.LastSentAt := now
        this.Last := {SessionKey: snapshot.SessionKey, Updated: snapshot.Updated,
            Minimum: snapshot.Minimum, Maximum: snapshot.Maximum, Target: target, At: now,
            Session: snapshot.Session, App: snapshot.App, Rate: snapshot.Rate}
    }
}

MediaClamp(position, minimum, maximum) => Min(maximum, Max(minimum, position))

MediaTarget(position, inputs, minimum, maximum) {
    ; Clamp each input in order: at the end, +10 then -1 means end minus 1.
    for seconds in inputs
        position := MediaClamp(position + seconds * 10000000, minimum, maximum)
    return Round(position)
}

MediaShowPosition(app, target, maximum, duration) {
    ToolTip(app "`nTarget: " MediaFormatTime(target) " / " MediaFormatTime(maximum))
    SetTimer(MediaHidePosition, -duration)
}

MediaHidePosition() => ToolTip()

MediaFormatTime(ticks) {
    seconds := Max(0, Floor(ticks / 10000000))
    return seconds >= 3600
        ? Format("{}:{:02}:{:02}", seconds // 3600, Mod(seconds // 60, 60), Mod(seconds, 60))
        : Format("{}:{:02}", seconds // 60, Mod(seconds, 60))
}

; ABI method slots are grouped by their owning interface, not by numeric value.
class MediaAbi {
    static Manager := {GetCurrentSession: 6}
    static ManagerStatics := {RequestAsync: 6}
    static Session := {SourceAppUserModelId: 6, GetTimelineProperties: 8,
        GetPlaybackInfo: 9, TryChangePlaybackPositionAsync: 24}
    static Playback := {Controls: 6, Status: 7, Rate: 10}
    static Controls := {IsPlaybackPositionEnabled: 20}
    static Timeline := {StartTime: 6, EndTime: 7, MinSeekTime: 8,
        MaxSeekTime: 9, Position: 10, LastUpdatedTime: 11}
    static Reference := {Value: 6}
    static AsyncInfo := {Status: 7, Cancel: 9}
    static AsyncOperation := {GetResults: 8}
    static Playing := 4
    static Started := 0
}

class MediaApi {
    __New(timeoutMs) {
        this.TimeoutMs := timeoutMs
        this.Manager := 0
    }

    Reset() => this.Manager := 0

    CurrentSession() {
        if !this.Manager
            this.Manager := MediaManager(this.TimeoutMs)
        return MediaGet(this.Manager, MediaAbi.Manager.GetCurrentSession)
    }

    ReadSnapshot() {
        session := this.CurrentSession()
        if !session
            return 0
        playback := MediaGet(session, MediaAbi.Session.GetPlaybackInfo)
        controls := MediaGet(playback, MediaAbi.Playback.Controls)
        if !MediaGet(controls, MediaAbi.Controls.IsPlaybackPositionEnabled, "uchar")
            return 0
        timeline := MediaGet(session, MediaAbi.Session.GetTimelineProperties)
        minimum := Max(MediaGet(timeline, MediaAbi.Timeline.StartTime, "int64"),
            MediaGet(timeline, MediaAbi.Timeline.MinSeekTime, "int64"))
        maximum := MediaGet(timeline, MediaAbi.Timeline.MaxSeekTime, "int64")
        if maximum <= minimum
            maximum := MediaGet(timeline, MediaAbi.Timeline.EndTime, "int64")
        if maximum <= minimum
            return 0
        position := MediaGet(timeline, MediaAbi.Timeline.Position, "int64")
        updated := MediaGet(timeline, MediaAbi.Timeline.LastUpdatedTime, "int64")
        rate := 0.0
        if MediaGet(playback, MediaAbi.Playback.Status, "int") = MediaAbi.Playing {
            rate := 1.0
            if reference := MediaGet(playback, MediaAbi.Playback.Rate)
                rate := MediaGet(reference, MediaAbi.Reference.Value, "double")
            DllCall("GetSystemTimeAsFileTime", "int64*", &now := 0)
            position += Max(0, now - updated) * rate
        }
        identity := ComObjQuery(session, "{00000000-0000-0000-C000-000000000046}")
        return {Session: session, SessionKey: identity.Ptr, App: this.SourceApp(session),
            Position: MediaClamp(position, minimum, maximum), Updated: updated,
            Minimum: minimum, Maximum: maximum, Rate: rate}
    }

    SourceApp(session) {
        ComCall(MediaAbi.Session.SourceAppUserModelId, session, "ptr*", &name := 0)
        try {
            buffer := DllCall("combase\WindowsGetStringRawBuffer", "ptr", name,
                "uint*", &length := 0, "ptr")
            return length ? StrGet(buffer, length, "UTF-16") : "Media"
        } finally {
            DllCall("combase\WindowsDeleteString", "ptr", name)
        }
    }

    BeginSeek(session, target) {
        ComCall(MediaAbi.Session.TryChangePlaybackPositionAsync, session,
            "int64", target, "ptr*", &operation := 0)
        return ComValue(13, operation, 1)
    }

    IsPending(operation) => MediaAsyncStatus(operation) = MediaAbi.Started
    SeekResult(operation) => MediaGet(operation, MediaAbi.AsyncOperation.GetResults, "uchar")
    Cancel(operation) => MediaCancel(operation)
}

MediaManager(timeoutMs) {
    static initialized := DllCall("combase\RoInitialize", "uint", 0, "int")
    name := "Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager"
    DllCall("combase\WindowsCreateString", "wstr", name, "uint", StrLen(name),
        "ptr*", &hstring := 0, "HRESULT")
    try {
        iid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "wstr", "{2050C4EE-11A0-57DE-AED7-C97C70338245}",
            "ptr", iid, "HRESULT")
        DllCall("combase\RoGetActivationFactory", "ptr", hstring, "ptr", iid,
            "ptr*", &factory := 0, "HRESULT")
        factory := ComValue(13, factory, 1)
        ComCall(MediaAbi.ManagerStatics.RequestAsync, factory, "ptr*", &operation := 0)
        return MediaAwait(ComValue(13, operation, 1), timeoutMs)
    } finally {
        DllCall("combase\WindowsDeleteString", "ptr", hstring)
    }
}

; Read an ABI property, taking ownership of returned COM references.
MediaGet(object, index, type := "ptr") {
    ComCall(index, object, type "*", &value := 0)
    return type = "ptr" && value ? ComValue(13, value, 1) : value
}

MediaAsyncStatus(operation) {
    info := ComObjQuery(operation, "{00000036-0000-0000-C000-000000000046}")
    return MediaGet(info, MediaAbi.AsyncInfo.Status, "int")
}

MediaCancel(operation) {
    info := ComObjQuery(operation, "{00000036-0000-0000-C000-000000000046}")
    ComCall(MediaAbi.AsyncInfo.Cancel, info)
}

; Only initial manager acquisition waits; seek operations are polled by Tick.
MediaAwait(operation, timeoutMs) {
    started := A_TickCount
    while MediaAsyncStatus(operation) = MediaAbi.Started {
        if A_TickCount - started >= timeoutMs {
            MediaCancel(operation)
            throw Error("Media manager initialization timed out")
        }
        Sleep(10)
    }
    return MediaGet(operation, MediaAbi.AsyncOperation.GetResults)
}
