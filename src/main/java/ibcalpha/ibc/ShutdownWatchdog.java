// This file is part of IBC.
// Copyright (C) 2004 Steven M. Kearns (skearns23@yahoo.com )
// Copyright (C) 2004 - 2018 Richard L King (rlking@aultan.com)
// For conditions of distribution and use, see copyright notice in COPYING.txt

// IBC is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// IBC is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with IBC.  If not, see <http://www.gnu.org/licenses/>.

package ibcalpha.ibc;

import java.awt.Window;
import java.lang.management.LockInfo;
import java.lang.management.ManagementFactory;
import java.lang.management.MonitorInfo;
import java.lang.management.ThreadInfo;
import java.lang.management.ThreadMXBean;

/**
 * Ends a JVM whose shutdown has hung.
 *
 * TWS's daily auto-restart ends with System.exit, and ibc.ps1 only starts TWS again once
 * the JVM has gone. If the exit deadlocks (seen with TWS 1050 on Java 25: install4j's exit
 * thread waits for the AWT shutdown hook, which needs the event dispatch thread, which is
 * blocked on install4j's ShutdownWaiter lock) the JVM stays up forever with no TWS window,
 * and nothing restarts it.
 *
 * The watchdog is armed when TWS shows its "Restart in progress" dialog or when the JVM
 * starts shutting down (a shutdown hook), whichever comes first. If the JVM is still
 * running ShutdownWatchdogSeconds later, it logs a thread dump and halts the JVM, skipping
 * the stuck shutdown hooks. (If it was armed by the dialog, the dialog has closed and the
 * JVM isn't shutting down, TWS has carried on, and the watchdog stops instead.) The exit code tells ibc.ps1 what was hanging:
 * {@link ErrorCodes#RESTART_HUNG} for an auto-restart (ibc.ps1 always starts TWS again,
 * without a login if TWS had written its autorestart file), {@link ErrorCodes#SHUTDOWN_HUNG}
 * for any other shutdown (ibc.ps1 restarts only if there's an autorestart file).
 */
class ShutdownWatchdog {

    private static final int DEFAULT_TIMEOUT_SECONDS = 120;

    // how long to wait for the log message and thread dump before halting anyway
    private static final long REPORT_TIMEOUT_MILLIS = 10_000;

    private static final Object _Lock = new Object();

    // guarded by _Lock
    private static boolean _Armed;
    private static boolean _ShuttingDown;

    private static volatile int _TimeoutSeconds = DEFAULT_TIMEOUT_SECONDS;

    private ShutdownWatchdog() { }

    static void install() {
        _TimeoutSeconds = Settings.settings().getInt("ShutdownWatchdogSeconds", DEFAULT_TIMEOUT_SECONDS);
        if (_TimeoutSeconds <= 0) {
            Utils.logToConsole("Shutdown watchdog is disabled (ShutdownWatchdogSeconds=" + _TimeoutSeconds + ")");
            return;
        }
        Utils.logToConsole("Shutdown watchdog: a restart or shutdown that takes more than " + _TimeoutSeconds +
                " seconds will be ended by halting the Java VM");

        // the hook must return at once, so that it doesn't delay a normal shutdown
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            synchronized (_Lock) {
                _ShuttingDown = true;
            }
            arm("the Java VM started shutting down", ErrorCodes.SHUTDOWN_HUNG, null);
        }, "IBC-ShutdownHook"));
    }

    /**
     * @return
     * true if a restart or shutdown has started (the countdown is running)
     */
    static boolean isArmed() {
        synchronized (_Lock) {
            return _Armed;
        }
    }

    /**
     * Starts the countdown, unless it's already running.
     * @param reason
     * what started the shutdown, for the log
     * @param exitCode
     * the exit code if the countdown expires
     * @param progressDialog
     * the dialog showing that a restart is in progress, or null. If the countdown expires
     * when this dialog has closed and the Java VM hasn't started shutting down, TWS has
     * carried on running (eg the restart didn't go ahead), so the watchdog stops rather
     * than halting the Java VM
     */
    static void arm(String reason, int exitCode, Window progressDialog) {
        if (_TimeoutSeconds <= 0) return;
        synchronized (_Lock) {
            if (_Armed) {
                Utils.logToConsole("Shutdown watchdog: " + reason + " (already watching)");
                return;
            }
            _Armed = true;
        }
        Utils.logToConsole("Shutdown watchdog: " + reason + "; the Java VM will be halted if it's still running in " +
                _TimeoutSeconds + " seconds");

        Thread watchdog = new Thread(() -> {
            Utils.pause(_TimeoutSeconds * 1000);
            synchronized (_Lock) {
                if (progressDialog != null && !progressDialog.isShowing() && !_ShuttingDown) {
                    Utils.logToConsole("Shutdown watchdog: TWS is still running " + _TimeoutSeconds + " seconds after " +
                            reason + ", but the restart is no longer in progress, so the watchdog has stopped");
                    _Armed = false;
                    return;
                }
            }
            halt(reason, exitCode);
        }, "IBC-ShutdownWatchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    // Logging blocks if another thread holds the output stream's lock or the pipe to ibc.ps1
    // is full, so it's done on a separate thread, and the Java VM is halted even if it hangs
    private static void halt(String reason, int exitCode) {
        Thread reporter = new Thread(() -> {
            Utils.logError("Shutdown watchdog: the Java VM is still running " + _TimeoutSeconds +
                    " seconds after " + reason + ": the shutdown has hung");
            logThreadDump();
            Utils.logToConsole("Exiting after error with exit code=" + exitCode);
            Utils.getOutStream().flush();
        }, "IBC-ShutdownWatchdogReport");
        reporter.setDaemon(true);
        reporter.start();
        try {
            reporter.join(REPORT_TIMEOUT_MILLIS);
        } catch (InterruptedException e) {
        }
        Runtime.getRuntime().halt(exitCode);
    }

    private static void logThreadDump() {
        try {
            ThreadMXBean threads = ManagementFactory.getThreadMXBean();
            long[] deadlocked = threads.findDeadlockedThreads();
            Utils.logToConsole("Thread dump follows" +
                    (deadlocked == null ? " (no Java-level deadlock detected)" : " (" + deadlocked.length + " threads deadlocked)"));
            for (ThreadInfo info : threads.dumpAllThreads(true, true)) {
                Utils.logRawToConsole(format(info));
            }
            Utils.logToConsole("End of thread dump");
        } catch (RuntimeException e) {
            Utils.logToConsole("Shutdown watchdog: can't produce a thread dump: " + e);
        }
        Utils.getOutStream().flush();
    }

    // like ThreadInfo.toString, but with the whole stack rather than the first 8 frames
    private static String format(ThreadInfo info) {
        StringBuilder sb = new StringBuilder();
        sb.append('"').append(info.getThreadName()).append("\" #").append(info.getThreadId());
        if (info.isDaemon()) sb.append(" daemon");
        sb.append(' ').append(info.getThreadState());
        if (info.getLockName() != null) sb.append(" on ").append(info.getLockName());
        if (info.getLockOwnerName() != null) {
            sb.append(" owned by \"").append(info.getLockOwnerName()).append("\" #").append(info.getLockOwnerId());
        }
        if (info.isInNative()) sb.append(" (in native)");
        sb.append(System.lineSeparator());

        StackTraceElement[] stack = info.getStackTrace();
        MonitorInfo[] monitors = info.getLockedMonitors();
        for (int depth = 0; depth < stack.length; depth++) {
            sb.append("\tat ").append(stack[depth]).append(System.lineSeparator());
            for (MonitorInfo monitor : monitors) {
                if (monitor.getLockedStackDepth() == depth) {
                    sb.append("\t- locked ").append(monitor).append(System.lineSeparator());
                }
            }
        }
        for (LockInfo synchronizer : info.getLockedSynchronizers()) {
            sb.append("\t- locked synchronizer ").append(synchronizer).append(System.lineSeparator());
        }
        return sb.toString();
    }
}
