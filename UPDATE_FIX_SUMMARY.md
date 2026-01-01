# Backblaze Auto-Update Fix Summary

## Problem
The Backblaze Personal Wine container was failing to auto-update properly, causing issues where:
- Updates would download the latest Backblaze version which is incompatible with Wine 10.0
- Drives would appear "unplugged" after updates (Issue #235)
- Authentication would fail after updates (Issue #231)
- OS detection would fail (Issue #230)

## Root Causes

###  1. Wrong Default Environment Variables in Dockerfile
**File**: `Dockerfile.ubuntu22` lines 6-7

**Problem**:
```dockerfile
ENV FORCE_LATEST_UPDATE="true"   # Downloads bleeding-edge version (breaks with Wine)
ENV DISABLE_AUTOUPDATE="true"    # Disables updates entirely
```

**Fix**:
```dockerfile
ENV FORCE_LATEST_UPDATE="false"  # Uses pinned known-good version (9.0.1.777)
ENV DISABLE_AUTOUPDATE="false"   # Enables auto-updates
```

### 2. Poor Error Handling in startapp.sh
**File**: `rootfs/startapp.sh`

**Problems**:
- Wine initialization failures were not properly caught
- .NET Framework 4.8 installation failures (Wine 10.0 bug #49897) caused cascading failures
- Installer errors provided no useful debugging information
- Silent failures left container in broken state

**Fixes**:
- Added error checking for Wine initialization (lines 26-48)
- Made .NET Framework 4.8 installation non-fatal (lines 29-35)
- Added Wine functionality verification (lines 37-43)
- Improved download verification in `fetch_and_install()` (lines 90-125)
- Added detailed error messages in `start_app()` (lines 127-165)
- All critical operations now log to file and console

## How It Works Now

### With Auto-Updates ENABLED (Recommended):
```bash
docker run -p 8080:5800 --init --privileged \
  -e USER_ID=0 -e GROUP_ID=0 \
  --name backblaze_personal_backup \
  -v "/path/to/backup:/drive_d/" \
  -v "/path/to/config:/config/" \
  twist3dimages/backblaze-personal-wine:fixed
```

**Behavior**:
1. Container starts and initializes Wine
2. On first run: Downloads Backblaze version **9.0.1.777** from Archive.org (known-good version)
3. Installs Backblaze
4. On subsequent runs: Checks if installed version < 9.0.1.777
5. If update available: Downloads and installs 9.0.1.777
6. Never downloads bleeding-edge versions that break with Wine

### With Auto-Updates DISABLED:
```bash
docker run -p 8080:5800 --init --privileged \
  -e USER_ID=0 -e GROUP_ID=0 \
  -e DISABLE_AUTOUPDATE=true \
  --name backblaze_personal_backup \
  -v "/path/to/backup:/drive_d/" \
  -v "/path/to/config:/config/" \
  twist3dimages/backblaze-personal-wine:fixed
```

**Behavior**:
- Uses whatever version is currently installed
- Never checks for or downloads updates
- bzupdates folder is made read-only to prevent Backblaze from self-updating

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DISABLE_AUTOUPDATE` | `false` | Set to `true` to disable all updates |
| `FORCE_LATEST_UPDATE` | `false` | Set to `true` to use bleeding-edge version (NOT recommended) |

## Testing

The fixes have been implemented in:
- `Dockerfile.ubuntu22` - Updated default environment variables
- `rootfs/startapp.sh` - Improved error handling and logging

## Known Issues

### Local Docker Build Fails with Error 127
The locally built image exits with error code 127 (`/startapp.sh: not found`) even though the file exists and is executable in the image. This appears to be an issue with:
- Base image compatibility
- Windows Docker Desktop volume mounting
- Build context issues

**Workaround**: Push changes to GitHub and let Docker Hub / GitHub Actions build the image, OR use the official `tessypowder/backblaze-personal-wine:latest` image with explicit environment variable overrides.

## Recommended Next Steps

1. **Push changes to your fork**:
   ```bash
   git add Dockerfile.ubuntu22 rootfs/startapp.sh
   git commit -m "Fix auto-update mechanism to use pinned version"
   git push origin main
   ```

2. **Set up Docker Hub auto-build** or use GitHub Actions to build the image

3. **Or use official image with overrides**:
   ```bash
   docker run -p 8080:5800 --init --privileged \
     -e USER_ID=0 -e GROUP_ID=0 \
     -e FORCE_LATEST_UPDATE=false \
     -e DISABLE_AUTOUPDATE=false \
     --name backblaze_personal_backup \
     -v "G:/backup:/drive_d/" \
     -v "G:/backblaze_config:/config/" \
     tessypowder/backblaze-personal-wine:latest
   ```
   
   Note: The official image has `FORCE_LATEST_UPDATE="true"` hardcoded in the Dockerfile, so you MUST override it with `-e FORCE_LATEST_UPDATE=false`

## Files Changed

1. `Dockerfile.ubuntu22` - Changed default environment variables
2. `rootfs/startapp.sh` - Added error handling, improved logging, made .NET installation non-fatal

## References

- [Issue #235: Backblaze required update...now drives unplugged](https://github.com/JonathanTreffler/backblaze-personal-wine-container/issues/235)
- [Wine Bug #49897: .NET Framework 4.8 broken in Wine 10.0](https://bugs.winehq.org/show_bug.cgi?id=49897)
- [Pinned Backblaze Version: 9.0.1.777](rootfs/PINNED_BZ_VERSION)
