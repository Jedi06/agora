/*******************************************************************************

    Contains a network-synchronized Clock implementation.

    There are three goals that need to be achieved with regards to
    time synchronization:

    1. Accuracy. This is the relative accuracy of each node's local
    clock compared to an external reference clock (NTP / World clock).

    2. Precision. This is measured as the relative difference between all of
    the nodes' local clocks compared to each other in the network.

    See also: https://en.wikipedia.org/wiki/File:Accuracy_and_precision.svg

    An average computer's local clock is prone to time drift,
    usually in the order of several seconds per day. There are various factors
    which influence the clock's time drift such as the system's temperature.

    More importantly, a computer may experience failure to contact NTP
    or have a misconfigured NTP configuration.

    This module contains a Clock implementation which periodically synchronizes
    its time with the rest of the network - this allows validator nodes to
    continue being part of consensus even if their own clock time drifts.
    In case of a large drift, there should be a mechanism of alerting the node
    operator to fix their node computer's NTP settings.

    Note that NTP can be prone to abuse
    (see https://en.wikipedia.org/wiki/NTP_server_misuse_and_abuse).

    On Posix systems one can check their NTP server configuration with:
    $ cat /etc/ntp.conf

    Resources:
    https://ethresear.ch/t/network-adjusted-timestamps/4187
    https://hackmd.io/x6CaC2OXQ-OTnaobQp39yA
    https://hackmd.io/X-uvqwe8TkmR-CJqMdfn6Q

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.network.Clock;

import agora.common.Task;
import agora.common.Types : TimePoint;
import agora.utils.Log;

import std.datetime.systime : StdClock = Clock;
import std.datetime.timezone : UTC;
import core.time;

/// Delegate used to calculate the time offset to apply in `networkTime`
public alias GetNetTimeOffset = bool delegate (out Duration) @safe nothrow;

/// Ditto
public class Clock
{
    /// used to retrieve the quorum median clock time
    private GetNetTimeOffset getNetTimeOffset;

    /// the offset for the current time, which may be negative
    private Duration net_time_offset;

    /// how often the clock should be synchronized with the network
    public const Duration ClockSyncInterval = 1.minutes;

    /***************************************************************************

        Instantiate the clock.

        The `start` routine must be called when the task manager is
        ready to set up timers.

        Params:
            getNetTimeOffset = delegate to call to calculate a net time offset
                               which will be used in the call to `networkTime`

    ***************************************************************************/

    public this (GetNetTimeOffset getNetTimeOffset) @safe @nogc nothrow pure
    {
        this.getNetTimeOffset = getNetTimeOffset;
    }

    /***************************************************************************

        Returns:
            the current network-adjusted clock time as a UNIX timestamp

    ***************************************************************************/

    public TimePoint networkTime () @safe nothrow
    {
        return this.utcTime() + this.net_time_offset.total!"seconds";
    }

    /***************************************************************************

        Returns:
            the current clock time (which may drift) as a UNIX timestamp

    ***************************************************************************/

    public TimePoint utcTime () @safe nothrow
    {
        auto ut = StdClock.currTime(UTC()).toUnixTime;
        assert(ut > 0);
        return TimePoint(ut);
    }

    /***************************************************************************

        Start periodically synchronizing this clock with the NTP source.

        The first sync is blocking (to properly initialize the clock),
        subsequent synchronizations are done asynchronously via a timer.

    ***************************************************************************/

    public ITimer start (ITaskManager taskman) @safe nothrow
    {
        this.synchronize();
        return taskman.setTimer(ClockSyncInterval, &this.synchronize);
    }

    /***************************************************************************

        Synchronize the clock with the network.
        Public to allow unittests to manually force a clock sync.

    ***************************************************************************/

    public void synchronize () @safe nothrow
    {
        Duration time_offset;
        if (this.getNetTimeOffset(time_offset))
            this.net_time_offset = time_offset;
    }
}

///
public class MockClock : Clock
{
    private TimePoint time;

    ///
    public this (TimePoint time)
    {
        super(null);
        this.time = time;
    }

    ///
    public void setTime (TimePoint time)
    {
        this.time = time;
    }

    /// returns time set by constructor
    public override TimePoint networkTime () @safe nothrow { return time;}

    /// returns time set by constructor
    public override TimePoint utcTime () @safe nothrow @nogc { return time;}

    /// do nothing
    public override ITimer start (ITaskManager) @safe nothrow { return null; }

    /// do nothing
    public override void synchronize () @safe nothrow {}
}
