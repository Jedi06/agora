/*******************************************************************************

    Test runner for our integration test suite

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module runner;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string : strip;

/// Directory where simple tests live
private immutable UnitPath = __FILE_FULL_PATH__.dirName.buildPath("unit");
/// Root on which to run dub describe
private immutable RootPath = __FILE_FULL_PATH__.dirName.dirName;

private int main (string[] args)
{
    size_t count;

    const compiler = args.length > 1 ? args[1] : "ldc2";
    const importPaths = getImportPaths();
    const lflags = getLflags();
    if (!importPaths.length || !lflags.length)
        return 1;
    const Args = [compiler, "-i", "-vcolumns" ] ~
        args[(args.length >= 2) + 1 .. $] ~
        "--d-version=Have_vibe_core" ~ "--preview=in" ~
        importPaths.map!(v => "-I" ~ v).array ~
        lflags.map!(v => "-L" ~ v).array;

    foreach (test; dirEntries(UnitPath, SpanMode.shallow))
    {
        writeln("Running test on ", test);
        auto pp = pipeProcess(Args ~ [ "-run", test ]);
        if (pp.pid.wait() != 0)
        {
            pp.stdout.byLine.each!(a => writeln("[stdout]\t", a));
            pp.stderr.byLine.each!(a => writeln("[stderr]\t", a));
            writeln("Test ", test, " failed!");
            return 1;
        }
        pp.stderr.byLine.each!(a => writeln("[stderr]\t", a));

        count++;
    }
    writeln("Ran ", count, " tests");
    return count != 0 ? 0 : 1;
}

/// Get the import path from dub
private string[] getImportPaths ()
{
    auto pp = pipeProcess(["dub", "--root=" ~ RootPath, "describe", "--import-paths"]);
    if (pp.pid.wait() != 0)
    {
        pp.stderr.byLine.each!(a => writeln("[fatal]\t", a));
        return null;
    }
    return pp.stdout.byLineCopy.map!strip.array;
}

/// Get the linker flags from dub
private string[] getLflags ()
{
    /// TODO: Those flags need to be hardcoded because of DUB issue
    /// https://github.com/dlang/dub/issues/1032
    version (none)
    {
        auto pp = pipeProcess(["dub", "--root=" ~ RootPath, "describe", "--data=lflags", "--data-list"]);
        if (pp.pid.wait() != 0)
        {
            pp.stderr.byLine.each!(a => writeln("[fatal]\t", a));
            return null;
        }
        return pp.stdout.byLineCopy.map!strip.array;
    }
    else version (Posix)
    {
        auto pp = pipeProcess(["pkg-config", "--libs", "sqlite3"]);
        if (pp.pid.wait() != 0)
        {
            pp.stderr.byLine.each!(a => writeln("[fatal]\t", a));
            return null;
        }
        auto lsqlite3 = pp.stdout.byLine.take(1).map!strip.front.splitter(' ').array.assumeUnique;
        return [ "-lsodium" ] ~ lsqlite3;
    }
    else version (Windows)
    {
        // Note: Only works with LDC, see https://github.com/dlang/dub/issues/1914
        return [ "-llibsodium" ];
    }
    else
        static assert(0, "Unhandled platform");
}
