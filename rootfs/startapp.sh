#!/bin/bash
set -x

# Define globals
local_version_file="${WINEPREFIX}dosdevices/c:/ProgramData/Backblaze/bzdata/bzreports/bzserv_version.txt"
install_exe_path="${WINEPREFIX}dosdevices/c:/"
log_file="${STARTUP_LOGFILE:-${WINEPREFIX}dosdevices/c:/backblaze-wine-startapp.log}"
custom_user_agent="backblaze-personal-wine (JonathanTreffler, +https://github.com/JonathanTreffler/backblaze-personal-wine-container), CFNetwork"

# Extracting variables from the PINNED_VERSION file
pinned_bz_version_file="/PINNED_BZ_VERSION"
pinned_bz_version=$(sed -n '1p' "$pinned_bz_version_file")
pinned_bz_version_url=$(sed -n '2p' "$pinned_bz_version_file")

# Only set FORCE_LATEST_UPDATE if not already set by user
if [ -z "$FORCE_LATEST_UPDATE" ]; then
    export FORCE_LATEST_UPDATE="true" #default to true since URL is excluded from archive.org
fi
export WINEARCH="win64"
export WINEDLLOVERRIDES="mscoree=" # Disable Mono installation

log_message() {
    echo "$(date): $1" >> "$log_file"
}

# Pre-initialize Wine
if [ ! -f "${WINEPREFIX}system.reg" ]; then
    echo "WINE: Wine not initialized, initializing"
    wineboot -i
    
    # Try to install .NET Framework 4.8, but don't fail if it doesn't work
    echo "WINE: Installing .NET Framework 4.8 (this may take 10-15 minutes)..."
    if ! WINETRICKS_ACCEPT_EULA=1 winetricks -q -f dotnet48 2>&1 | tee -a "$log_file"; then
        echo "WINE: Warning - .NET Framework 4.8 installation had issues, but continuing..."
        log_message "WINE: .NET Framework 4.8 installation had issues, but continuing..."
    fi
    
    # Set Windows version to Windows 10
    WINETRICKS_ACCEPT_EULA=1 winetricks -q win10
    
    # Verify Wine is working
    if ! wine64 --version > /dev/null 2>&1; then
        echo "WINE: ERROR - Wine is not functioning properly!"
        log_message "WINE: ERROR - Wine is not functioning properly!"
        sleep infinity
    fi
    
    log_message "WINE: Initialization done and set to Windows 10"
fi

#Configure Extra Mounts
for x in {d..z}
do
    if test -d "/drive_${x}" && ! test -d "${WINEPREFIX}dosdevices/${x}:"; then
        log_message "DRIVE: drive_${x} found but not mounted, mounting..."
        ln -s "/drive_${x}/" "${WINEPREFIX}dosdevices/${x}:"
    fi
done

# Set Virtual Desktop
cd $WINEPREFIX
if [ "$DISABLE_VIRTUAL_DESKTOP" = "true" ]; then
    log_message "WINE: DISABLE_VIRTUAL_DESKTOP=true - Virtual Desktop mode will be disabled"
    winetricks vd=off
else
    # Check if width and height are defined
    if [ -n "$DISPLAY_WIDTH" ] && [ -n "$DISPLAY_HEIGHT" ]; then
    log_message "WINE: Enabling Virtual Desktop mode with $DISPLAY_WIDTH:$DISPLAY_HEIGHT aspect ratio"
    winetricks vd="$DISPLAY_WIDTH"x"$DISPLAY_HEIGHT"
    else
        # Default aspect ratio
        log_message "WINE: Enabling Virtual Desktop mode with recommended aspect ratio"
        winetricks vd="1280x1024"
    fi
fi

# Disclaimer and bzupdates folder protection
bzupdates_folder="${WINEPREFIX}drive_c/Program Files (x86)/Backblaze/bzupdates"
if [ "$DISABLE_AUTOUPDATE" = "true" ]; then
    echo "Auto-updates are disabled. Backblaze won't be updated."
    # Make bzupdates folder read-only to prevent Backblaze from auto-updating itself
    if [ -d "$bzupdates_folder" ]; then
        log_message "UPDATER: Making bzupdates folder read-only to prevent Backblaze auto-updates"
        chmod -R 555 "$bzupdates_folder" 2>/dev/null || log_message "UPDATER: Warning - Could not set bzupdates folder to read-only"
    fi
else
    # Check the status of FORCE_LATEST_UPDATE
    if [ "$FORCE_LATEST_UPDATE" = "true" ]; then
        echo "FORCE_LATEST_UPDATE is enabled which may brick your installation."
    else
        echo "FORCE_LATEST_UPDATE is disabled. Using known-good version of Backblaze."
    fi
    # Ensure bzupdates folder is writable when auto-updates are enabled
    if [ -d "$bzupdates_folder" ]; then
        chmod -R 755 "$bzupdates_folder" 2>/dev/null || true
    fi
fi

# Function to handle errors
handle_error() {
    echo "Error: $1" >> "$log_file"
    log_message "ERROR: $1"
    echo "ERROR: $1"
    # Don't automatically start app on error - let caller decide
    return 1
}

fetch_and_install() {
    if ! cd "$install_exe_path"; then
        log_message "INSTALLER: ERROR - Cannot navigate to $install_exe_path"
        return 1
    fi
    
    # Download the installer
    if [ "$FORCE_LATEST_UPDATE" = "true" ]; then
        log_message "INSTALLER: FORCE_LATEST_UPDATE=true - downloading latest version from Backblaze"
        echo "Downloading latest Backblaze version..."
        if ! curl -L "https://www.backblaze.com/win32/install_backblaze.exe" --output "install_backblaze.exe" 2>&1 | tee -a "$log_file"; then
            log_message "INSTALLER: Failed to download latest version from Backblaze"
            return 1
        fi
    else
        log_message "INSTALLER: FORCE_LATEST_UPDATE=false - downloading pinned version $pinned_bz_version from archive.org"
        echo "Downloading pinned Backblaze version $pinned_bz_version..."
        if ! curl -A "$custom_user_agent" -L "$pinned_bz_version_url" --output "install_backblaze.exe" 2>&1 | tee -a "$log_file"; then
            log_message "INSTALLER: Failed to download from $pinned_bz_version_url"
            return 1
        fi
    fi
    
    # Verify download
    if [ ! -f "install_backblaze.exe" ] || [ ! -s "install_backblaze.exe" ]; then
        log_message "INSTALLER: Downloaded file is missing or empty"
        return 1
    fi
    
    log_message "INSTALLER: Download complete, starting installation (this may take several minutes)..."
    echo "Installing Backblaze (this will take 5-10 minutes)..."
    
    # Run the installer with better error handling
    if WINEARCH="$WINEARCH" WINEPREFIX="$WINEPREFIX" wine64 "install_backblaze.exe" 2>&1 | tee -a "$log_file"; then
        log_message "INSTALLER: Installer process completed"
        return 0
    else
        log_message "INSTALLER: Installer process failed"
        return 1
    fi
}

start_app() {
    if [ -f "$local_version_file" ]; then
        local_version=$(cat "$local_version_file" 2>/dev/null || echo "unknown")
        log_message "STARTAPP: Starting Backblaze version $local_version"
        echo "Starting Backblaze version $local_version"
    else
        log_message "STARTAPP: Starting Backblaze (version file not found)"
        echo "Starting Backblaze (version file not found)"
    fi
    
    if [ ! -f "${WINEPREFIX}drive_c/Program Files (x86)/Backblaze/bzbui.exe" ]; then
        log_message "STARTAPP: ERROR - bzbui.exe not found. Application may not be installed."
        echo "===================================================================="
        echo "ERROR: Backblaze is not installed!"
        echo ""
        echo "This usually means the installation failed."
        echo "Check the log file at: $log_file"
        echo ""
        echo "Common causes:"
        echo "  - Wine failed to initialize (check Wine installation)"
        echo "  - .NET Framework 4.8 failed to install"
        echo "  - Backblaze installer download failed"
        echo "  - Backblaze installer incompatible with Wine version"
        echo ""
        echo "Container will sleep indefinitely. Check logs with: docker logs <container>"
        echo "===================================================================="
        sleep infinity
        return 1
    fi
    
    log_message "STARTAPP: Launching bzbui.exe"
    echo "Launching Backblaze UI..."
    
    # Wait a moment for Wine to be ready
    sleep 2
    
    # Launch Backblaze in background and capture any errors
    if wine64 "${WINEPREFIX}drive_c/Program Files (x86)/Backblaze/bzbui.exe" -noquiet 2>&1 | tee -a "$log_file" &
    then
        log_message "STARTAPP: Backblaze UI launched successfully"
        echo "Backblaze is now running. Access the web interface at http://localhost:5800"
    else
        log_message "STARTAPP: ERROR - Failed to launch Backblaze UI"
        echo "ERROR: Failed to launch Backblaze. Check logs at: $log_file"
    fi
    
    # Give the app time to start and display
    sleep 3
    log_message "STARTAPP: Backblaze should now be running"
    sleep infinity
}

if [ -f "${WINEPREFIX}drive_c/Program Files (x86)/Backblaze/bzbui.exe" ]; then
    check_url_validity() {
        url="$1"
        if http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url"); then
            if [ "$http_code" -eq 200 ]; then
                content_type=$(curl -s -I "$url" | grep -i content-type | cut -d ':' -f2)
                if echo "$content_type" | grep -q "xml"; then
                    return 0 # Valid XML content found
                fi
            fi
        fi
        return 1 # Invalid or unavailable content
    }

    compare_versions() {
        local_version="$1"
        compare_version="$2"

        if dpkg --compare-versions "$local_version" lt "$compare_version"; then
            return 0 # The compare_version is higher
        else
            return 1 # The local version is higher or equal
        fi
    }



    # Check if auto-updates are disabled
    if [ "$DISABLE_AUTOUPDATE" = "true" ]; then
        log_message "UPDATER: DISABLE_AUTOUPDATE=true, Auto-updates are disabled. Starting Backblaze without updating."
        start_app
        exit 0
    fi

    # Update process for force_latest_update set to true or not set
    if [ "$FORCE_LATEST_UPDATE" = "true" ]; then
        # Main auto update logic
        if [ -f "$local_version_file" ]; then
            log_message "UPDATER: FORCE_LATEST_UPDATE=true, checking for a new version"
            urls="
                https://ca000.backblaze.com/api/clientversion.xml
                https://ca001.backblaze.com/api/clientversion.xml
                https://ca002.backblaze.com/api/clientversion.xml
                https://ca003.backblaze.com/api/clientversion.xml
                https://ca004.backblaze.com/api/clientversion.xml
                https://ca005.backblaze.com/api/clientversion.xml
            "

            for url in $urls; do
                if check_url_validity "$url"; then
                    if ! xml_content=$(curl -s "$url"); then
                        log_message "UPDATER: Failed to fetch XML from $url, trying next URL"
                        continue
                    fi
                    xml_version=$(echo "$xml_content" | grep -o '<update win32_version="[0-9.]*"' | cut -d'"' -f2)
                    if ! local_version=$(cat "$local_version_file" 2>/dev/null); then
                        log_message "UPDATER: Failed to read local version file, starting app"
                        start_app
                        exit 0
                    fi
                    log_message "UPDATER: Installed Version=$local_version"
                    log_message "UPDATER: Latest Version=$xml_version"
                    if compare_versions "$local_version" "$xml_version"; then
                        log_message "UPDATER: Newer version found - downloading and installing the newer version..."
                        if fetch_and_install; then
                            log_message "UPDATER: Update completed successfully"
                            start_app
                        else
                            log_message "UPDATER: Update failed, but starting app anyway with current version"
                            start_app
                        fi
                    else
                        log_message "UPDATER: The installed version is up to date."
                        start_app # Exit autoupdate and start app
                    fi
                    exit 0  # Exit after handling this version check
                fi
            done

            # If we got here, no valid URL was found
            log_message "UPDATER: ERROR - No valid XML content found or all URLs are unavailable."
            echo "ERROR: Cannot check for updates - Backblaze API unavailable"
            log_message "UPDATER: Starting app with current version"
            start_app
            exit 0
        else
            log_message "UPDATER: ERROR - Local version file not found but app is installed"
            echo "ERROR: Version file missing but Backblaze appears to be installed"
            log_message "UPDATER: Starting app anyway"
            start_app
            exit 0
        fi
    else
        # Update process for force_latest_update set to false or anything else
        if [ -f "$local_version_file" ]; then
            local_version=$(cat "$local_version_file") || handle_error "UPDATER: Failed to read local version file"
            log_message "UPDATER: FORCE_LATEST_UPDATE=false"
            log_message "UPDATER: Installed Version=$local_version"
            log_message "UPDATER: Pinned Version=$pinned_bz_version"

            if compare_versions "$local_version" "$pinned_bz_version"; then
                log_message "UPDATER: Pinned version ($pinned_bz_version) is newer than installed ($local_version)"
                log_message "UPDATER: Downloading and installing pinned version..."
                if fetch_and_install; then
                    # Check if version was actually updated
                    if [ -f "$local_version_file" ]; then
                        new_version=$(cat "$local_version_file" 2>/dev/null || echo "$local_version")
                        if [ "$new_version" != "$local_version" ]; then
                            log_message "UPDATER: Successfully updated from $local_version to $new_version"
                        else
                            log_message "UPDATER: Warning - Version file not updated after install. Install may have failed."
                        fi
                    fi
                    start_app
                else
                    log_message "UPDATER: Update failed, starting app with current version $local_version"
                    start_app
                fi
            else
                log_message "UPDATER: Installed version ($local_version) is up to date with pinned version ($pinned_bz_version)"
                start_app
            fi
            exit 0  # Exit after version check
        else
            handle_error "UPDATER: Local version file does not exist. Exiting updater."
        fi
    fi
else # Client currently not installed
    log_message "INSTALLER: Backblaze not installed, performing initial installation..."
    if [ "$DISABLE_AUTOUPDATE" = "true" ]; then
        log_message "INSTALLER: Note - DISABLE_AUTOUPDATE=true, but initial installation is required"
    fi
    
    if fetch_and_install; then
        log_message "INSTALLER: Initial installation completed"
        # Verify installation
        if [ -f "${WINEPREFIX}drive_c/Program Files (x86)/Backblaze/bzbui.exe" ]; then
            log_message "INSTALLER: Backblaze executable found, installation successful"
            start_app
        else
            log_message "INSTALLER: ERROR - Backblaze executable not found after installation"
            echo "===================================================================="
            echo "INSTALLATION FAILED!"
            echo ""
            echo "The Backblaze installer ran but did not install the application."
            echo "This usually means:"
            echo "  - Wine is not properly configured"
            echo "  - The Backblaze installer is incompatible with this Wine version"
            echo "  - .NET Framework installation failed"
            echo ""
            echo "Check logs at: $log_file"
            echo "===================================================================="
            sleep infinity
        fi
    else
        log_message "INSTALLER: Initial installation failed"
        echo "===================================================================="
        echo "INSTALLATION FAILED!"
        echo ""
        echo "Could not download or run the Backblaze installer."
        echo "Check logs at: $log_file"
        echo "===================================================================="
        sleep infinity
    fi
fi
