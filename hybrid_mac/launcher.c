/*
 * Bundle launcher for the macOS build of 植物大战僵尸杂交重制版 (Godot 4.7 .NET).
 *
 * This is the app's CFBundleExecutable (Contents/MacOS/<name>). It replaces itself, in the same process, with the real
 * Godot binary Contents/MacOS/<name>.bin through execv(), so LaunchServices, Finder, `open -W` and the Dock see one
 * process from start to exit. Before the exec it
 *   - adds Contents/Frameworks/libPvzHybridMac.dylib to DYLD_INSERT_LIBRARIES (kept in front of any value the caller
 *     already set), so dyld loads the helper into the game process. The engine binary is signed ad hoc without the
 *     hardened runtime and without restricted segments, so dyld honours the variable;
 *   - passes every argument through unchanged (argv[0] becomes the real binary).
 * The pack is not passed with --main-pack: the official 4.7 release templates are built with disable_path_overrides
 * and abort when --main-pack is given ("this Godot binary was compiled without support for path overrides"). They
 * find Contents/Resources/<name>.pck by themselves, because the pack lookup uses the executable's base name with its
 * extension removed (<name>.bin -> <name>.pck).
 * A missing helper library is not fatal: the game then starts without it.
 */
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define HELPER_LIBRARY "libPvzHybridMac.dylib"

static int path_exists(const char *path)
{
	struct stat st;
	return stat(path, &st) == 0;
}

int main(int argc, char **argv)
{
	char exe[PATH_MAX];
	uint32_t size = sizeof exe;
	if (_NSGetExecutablePath(exe, &size) != 0)
	{
		fprintf(stderr, "PvZHybrid launcher: executable path too long\n");
		return 127;
	}
	char self[PATH_MAX];
	if (realpath(exe, self) == NULL)
		strlcpy(self, exe, sizeof self);

	// self = <bundle>/Contents/MacOS/<name>
	char *slash = strrchr(self, '/');
	if (slash == NULL)
	{
		fprintf(stderr, "PvZHybrid launcher: unexpected executable path %s\n", self);
		return 127;
	}
	*slash = '\0';
	const char *name = slash + 1;
	char macos[PATH_MAX], contents[PATH_MAX];
	strlcpy(macos, self, sizeof macos);
	strlcpy(contents, self, sizeof contents);
	char *up = strrchr(contents, '/');
	if (up != NULL)
		*up = '\0';

	char bin[PATH_MAX], lib[PATH_MAX];
	snprintf(bin, sizeof bin, "%s/%s.bin", macos, name);
	snprintf(lib, sizeof lib, "%s/Frameworks/%s", contents, HELPER_LIBRARY);

	if (path_exists(lib))
	{
		const char *old = getenv("DYLD_INSERT_LIBRARIES");
		if (old != NULL && old[0] != '\0' && strstr(old, lib) == NULL)
		{
			size_t len = strlen(lib) + 1 + strlen(old) + 1;
			char *both = malloc(len);
			if (both != NULL)
			{
				snprintf(both, len, "%s:%s", lib, old);
				setenv("DYLD_INSERT_LIBRARIES", both, 1);
				free(both);
			}
		}
		else if (old == NULL || old[0] == '\0')
			setenv("DYLD_INSERT_LIBRARIES", lib, 1);
	}
	else
		fprintf(stderr, "PvZHybrid launcher: %s not found; starting without the helper\n", lib);

	(void)argc;
	argv[0] = bin;
	execv(bin, argv);
	fprintf(stderr, "PvZHybrid launcher: cannot run %s: %s\n", bin, strerror(errno));
	return 127;
}
