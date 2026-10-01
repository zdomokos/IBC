You are welcome to contribute to IBC. Here are some of the ways you can help:

- correct mistakes or improve the quality of documentation: for example
  the User Guide or any of the text in the repository

- contribute to the [IBC User Group](https://groups.io/g/IBC)

- suggest ways to make IBC better or more useful

- submit pull requests to enhance or correct the code or the script files


Please bear in mind that IBC is a small, narrowly focussed project. Its
only purpose is to automate aspects of TWS and Gateway operation that would
otherwise require manual intervention at runtime. Note the following:

- IBC is *not* a tool for configuring TWS: the user must configure the TWS
  settings as required through the means provided in TWS.

- IBC is *not* a management mechanism for TWS, so it cannot be extended to
  provide for such things as restarting TWS after a failure. IBC and TWS run
  in the same process, and if one exits so does the other.

You may find the following guidelines helpful before starting work on a
contribution to the project:

1. **Discuss it first**: it's wise to raise an issue on the
   [GitHub repository](https://github.com/ibcalpha/ibc) explaining what you
   propose to do. There may be reasons why your proposed change is unlikely
   to be accepted, or someone else may already be working on something
   similar, or it may even have been proposed and rejected before. You can
   also discuss suggestions for improvement on the
   [IBC User Group](https://groups.io/g/IBC).

2. **Cross-platform**: in general changes must work on all supported
   platforms. In particular the Java source code should be cross-platform.
   Please make sure to test thoroughly on all platforms, and for both TWS
   and the Gateway, before submitting your pull request. If you can't do this,
   then please make clear in your pull request what testing you have done.

3. **Broad scope**: improvements should be potentially useful to a significant
   proportion of the user base.

4. **Non-developer users**: a lot of IBC users aren't developers. It must be
   easy for them to use any improvements. In particular, you should ensure
   that the [configuration file](resources/config.ini) and/or
   [user guide](userguide.md) adequately reflect changes.

5. **Backward compatibility**: new versions should not force users of previous
   versions to change their configuration or script files (ie no surprises),
   unless this is absolutely essential. Obviously it may be necessary to
   introduce new settings into the [configuration file](resources/IBC.ini)
   or enhance the script files, but this should be done in such a way that
   if a user moves to the new version of IBC without making any changes
   their TWS/Gateway will continue to operate exactly as before.

6. **Respect IB T&C**: changes must not be an infringement of the intent or
   provisions of IB's Terms and Conditions. For example, there should be no
   attempt to bypass the requirement to enter a code during logon for users
   enrolled in IB's security program.

7. **Style**: please maintain the same style as the existing code unless
   you've discussed a refactor with the current maintainers via email or a
   GitHub [Issue](https://github.com/IbcAlpha/IBC/issues)

How to build IBC
================

IBC is built with [Gradle](https://gradle.org/), using the Gradle wrapper
included in the repository, so the only thing you need to install is a
JDK, version 17 or later. The wrapper downloads the right version of Gradle
the first time you run it.

The build expects to find an `IBC_BIN` environment variable that specifies
a folder containing the TWS jar files. This enables the compiler to locate
the TWS and Gateway entrypoints to give an error-free compilation. You can
instead pass the folder on the command line with `-PibcBin=<folder>`.

This folder could be in your TWS installation directory (for example
C:\JtsE1\jars), or you could create a separate directory and copy the
jar files into it (this would avoid problems should TWS be uninstalled,
or a new version installed). Note that it doesn't matter which version
of TWS you use: package and class names are always the same.

If you're using an IDE, such as IntelliJ IDEA, Eclipse or NetBeans, to
produce a modified version of IBC, open the folder as a Gradle project and
set the `IBC_BIN` environment variable permanently.

From the repository root (use `gradlew` on Windows, `./gradlew` elsewhere):

    gradlew jar      builds build/libs/IBC.jar
    gradlew          builds the distribution ZIP files in build/dist, and
                     updates resources/IBC.jar and resources/version
    gradlew clean    deletes the build folder

Note that the `version` property in [gradle.properties](gradle.properties)
is used in generating the file names for the distribution ZIP files, is
compiled into IBC (the `IbcVersionInfo` class is generated during the
build), and is also put in the [version](resources/version) file which is
used by the script files.
