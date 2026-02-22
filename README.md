# Setting Up Time Machine on Ubiquiti UDM Pro / USM Pro Max

A complete guide to configuring your UDM Pro or USM Pro Max as a Time Machine backup destination for multiple Macs.

## ⚠️ IMPORTANT DISCLAIMER

**READ THIS BEFORE PROCEEDING**

This guide involves using the Command Line Interface (CLI) to modify your UDM Pro configuration. According to Ubiquiti's Terms of Service and End User License Agreement:

- Using CLI can potentially harm Ubiquiti devices and result in lost access to them and their data
- Modifying devices outside of their normal operational scope may **permanently and irrevocably void any applicable warranty**
- You proceed at your own risk

**By following this guide, you acknowledge that:**
- You have read and understand Ubiquiti's Terms of Service and EULA
- You accept all risks associated with modifying your UDM Pro via CLI
- **The author(s) of this guide take no responsibility for any damage to your UDM Pro, data loss, warranty void, or any other issues that may arise**
- You are solely responsible for backing up your UDM Pro configuration before proceeding
- This is an unsupported configuration and Ubiquiti support may not assist with issues arising from these modifications

**Recommendations:**
- Back up your UDM Pro configuration before starting
- Test on a non-production device if possible
- Document all changes you make
- Understand each command before executing it
- Have a recovery plan in case something goes wrong

**If you are not comfortable with these risks, do not proceed with this guide.**

---

## Overview

This guide will help you configure your Ubiquiti Dream Machine Pro (UDM Pro) or Unifi Security Max Pro (USM Pro Max) to serve as a network Time Machine backup destination. The setup supports multiple Macs backing up simultaneously to the same share, with each Mac maintaining its own separate backup.

### What You'll Need

- Ubiquiti UDM Pro with installed hard drive **OR** USM Pro Max with dual disk RAID-1 configuration
- SSH access to your device (root access)
- Internet connectivity on your device (to install packages via apt)
- One or more Macs running macOS

**Software that will be installed:**
- Samba (SMB file sharing server)
- Avahi daemon (for network discovery via mDNS)

### Disk Space

This guide supports two configurations:

**UDM Pro**: Single 16TB disk mounted at `/volume1`
**USM Pro Max**: Dual disk RAID-1 configuration (e.g., two 14.6TB disks = 14.5TB usable space after RAID-1 mirroring)

The RAID-1 configuration on USM Pro Max provides redundancy - if one disk fails, your data remains safe on the other disk.

**Note on RAID-1**: USM Pro Max typically comes with RAID-1 pre-configured via mdadm (usually `/dev/md3`). You can verify this with:
```bash
cat /proc/mdstat
mdadm --detail /dev/md3
```

## Step 1: Install and Verify Prerequisites

First, SSH into your device (replace IP address with your device's IP):

```bash
ssh root@192.168.1.1
```

### Install Samba and Avahi

If Samba and Avahi are not already installed, install them:

```bash
# Update package lists
apt update

# Install Samba and Avahi
apt install -y samba avahi-daemon

# Verify installation
which smbd avahi-daemon
```

You should see paths like `/usr/sbin/smbd` and `/usr/sbin/avahi-daemon`.

### Verify Disk Space

Check that your disk is mounted and has space:

```bash
df -h | grep volume1
```

You should see your large disk mounted at `/volume1` with plenty of free space.

**Note**: Some UDM Pro setups may already have Samba and Avahi installed. If the installation commands fail or indicate packages are already installed, that's fine - proceed to the next step.

## Step 2: Create Time Machine Directory

Create a dedicated directory for Time Machine backups:

```bash
mkdir -p /volume1/timemachine
```

## Step 3: Create Dedicated Time Machine User

For security and proper permissions, create a dedicated user for Time Machine:

```bash
# Create system user (no login shell)
useradd -M -s /usr/sbin/nologin timemachine

# Set ownership of the Time Machine directory
chown -R timemachine:timemachine /volume1/timemachine
chmod 777 /volume1/timemachine
```

Now add this user to Samba with a password:

```bash
# Add Samba user (you'll be prompted for password twice)
# Use a strong password - we'll use 'timemachine' for this example
printf 'timemachine\ntimemachine\n' | smbpasswd -a -s timemachine

# Enable the user
smbpasswd -e timemachine
```

## Step 4: Configure Samba for Time Machine

Edit `/etc/samba/smb.conf` and add the following configuration at the end:

```bash
cat >> /etc/samba/smb.conf << 'EOF'

# Time Machine Share
[TimeMachine]
   comment = Time Machine Backup
   path = /volume1/timemachine
   browseable = yes
   writable = yes
   valid users = timemachine
   force user = timemachine
   force group = timemachine
   create mask = 0600
   directory mask = 0700
   vfs objects = catia fruit streams_xattr
   fruit:aapl = yes
   fruit:time machine = yes
   fruit:model = MacSamba
   fruit:metadata = stream
   fruit:veto_appledouble = no
   fruit:posix_rename = yes
   fruit:zero_file_id = yes
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
EOF
```

**Important Note for Stability**: The `fruit:time machine max size` parameter is **intentionally NOT included** in this configuration because:

1. **ARM Architecture Bug**: Both UDM Pro and USM Pro Max use ARM/aarch64 architecture, where this parameter is broken (Samba bug #13622)
2. **Reliability**: Omitting this parameter prevents Error Code 50 and other backup failures
3. **Space Management**: Time Machine will naturally use available space without needing explicit limits

This configuration is specifically tailored for Time Machine stability and reliability. Do not add the `fruit:time machine max size` parameter unless you've verified your device uses x86_64 architecture (unlikely).

### Configuration Explanation

- **path**: Directory where backups are stored
- **valid users**: Only the timemachine user can access
- **force user/group**: All files are owned by timemachine user
- **create/directory mask**: Proper permissions for backup files (0600/0700 ensures security)
- **vfs objects**: Essential VFS modules for macOS compatibility
  - `catia`: Filename character translation
  - `fruit`: Apple-specific extensions for Time Machine
  - `streams_xattr`: Extended attribute support
- **fruit:aapl = yes**: Enables Apple extensions
- **fruit:time machine = yes**: Advertises this as a Time Machine destination
- **fruit:model = MacSamba**: Identifies as Mac-compatible device
- **fruit:metadata = stream**: Stores metadata in streams for compatibility
- **fruit:zero_file_id = yes**: Compatibility with various macOS versions
- **fruit:posix_rename = yes**: Enables atomic renames for reliability
- **fruit:wipe_intentionally_left_blank_rfork = yes**: Cleans up resource forks properly
- **fruit:delete_empty_adfiles = yes**: Removes empty AppleDouble files

All fruit parameters are specifically tuned for Time Machine reliability and performance.

## Step 5: Configure Avahi for Time Machine Discovery

Create an Avahi service file so Macs can automatically discover the Time Machine share:

```bash
mkdir -p /etc/avahi/services

cat > /etc/avahi/services/smb.service << 'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>9</port>
    <txt-record>model=MacSamba</txt-record>
  </service>
  <service>
    <type>_adisk._tcp</type>
    <port>9</port>
    <txt-record>dk0=adVN=TimeMachine,adVF=0x82</txt-record>
    <txt-record>sys=waMA=0,adVF=0x100</txt-record>
  </service>
</service-group>
EOF
```

## Step 6: Validate and Restart Services

Validate the Samba configuration:

```bash
testparm -s
```

Look for the `[TimeMachine]` section in the output. You should see "Loaded services file OK."

Restart the services:

```bash
# Restart Samba
systemctl restart smbd nmbd

# Reload Avahi (it's already running)
kill -HUP $(cat /var/run/avahi-daemon/pid)

# Verify services are running
systemctl status smbd nmbd
ps aux | grep avahi
```

## Step 7: Connect Your Mac

### Method 1: Using System Settings (Recommended)

1. Open **System Settings** on your Mac
2. Go to **General > Time Machine**
3. Click **Select Disk** (or the **+** button)
4. You should see **UDM-PRO-MAX** or **TimeMachine** in the list
5. Select it
6. When prompted for credentials:
   - Username: `timemachine`
   - Password: `timemachine` (or whatever you set)
7. Click **Use Disk**
8. Click **Back Up Now** to start your first backup

### Method 2: Using Finder

1. In Finder, press **⌘+K** (Command-K) to open "Connect to Server"
2. Enter: `smb://timemachine@192.168.1.1/TimeMachine`
3. Click **Connect**
4. Enter the password when prompted
5. Then go to **System Settings > General > Time Machine**
6. Click **Select Disk** and select the mounted share
7. Click **Use Disk**

### Method 3: Using Command Line (Requires Full Disk Access)

If Terminal has Full Disk Access permission:

```bash
# Enable Time Machine
sudo tmutil enable

# Set the destination
sudo tmutil setdestination smb://timemachine@192.168.1.1/TimeMachine

# Start backup
sudo tmutil startbackup
```

## Step 8: Automate Recovery After Firmware Updates

UDM Pro and USM Pro Max firmware updates wipe apt-installed packages and `/etc` configs. The `/data` directory is **persistent storage** that survives firmware updates — so we store config backups and the boot script there.

This step installs a boot script into the **native Ubiquiti boot hook system** (`bootup-bottom-invoke.service`), which is baked into the firmware squashfs and runs on every boot. The hook directory at `/usr/lib/ubnt/hooks/system/bootup-bottom/` is not managed by any dpkg package, so custom scripts dropped there are preserved across firmware updates. The actual script lives in `/data/timemachine/` (persistent storage), so it has two layers of survival protection.

### 8a: Create Persistent Backup Directory

```bash
mkdir -p /data/timemachine
```

### 8b: Save Config Files to Persistent Storage

Save the TimeMachine Samba share block:

```bash
cat >> /data/timemachine/smb-timemachine.conf << 'EOF'

# Time Machine Share
[TimeMachine]
   comment = Time Machine Backup
   path = /volume1/timemachine
   browseable = yes
   writable = yes
   valid users = timemachine
   force user = timemachine
   force group = timemachine
   create mask = 0600
   directory mask = 0700
   vfs objects = catia fruit streams_xattr
   fruit:aapl = yes
   fruit:time machine = yes
   fruit:model = MacSamba
   fruit:metadata = stream
   fruit:veto_appledouble = no
   fruit:posix_rename = yes
   fruit:zero_file_id = yes
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
EOF
```

Save the Avahi service file:

```bash
cp /etc/avahi/services/smb.service /data/timemachine/avahi-smb.service
```

Back up the Samba password database:

```bash
cp /var/lib/samba/private/passdb.tdb /data/timemachine/passdb.tdb
```

### 8c: Install the Boot Script

Download the script into persistent storage:

```bash
curl -o /data/timemachine/99-timemachine.sh \
  https://raw.githubusercontent.com/scttfrdmn/udm-pro-timemachine/main/scripts/99-timemachine.sh
chmod +x /data/timemachine/99-timemachine.sh
```

Install a small wrapper in the native Ubiquiti boot hook directory:

```bash
cat > /usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh << 'EOF'
#!/bin/bash
exec /data/timemachine/99-timemachine.sh "$@"
EOF
chmod +x /usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh
```

### 8d: Verify the Boot Script

Test it runs cleanly right now:

```bash
bash /usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh '{}'
```

You should see output like:
```
[2026-01-10 12:00:00] Time Machine boot setup complete
```

And check the system log:

```bash
grep timemachine-boot /var/log/syslog | tail -10
```

> **Do not attempt to "simulate" a firmware update** by running `apt purge samba` or similar commands. This will immediately break your live system — it is not a simulation. The only real test of the recovery mechanism is an actual firmware update.

### How It Works

#### UDM Pro Filesystem Architecture

The UDM Pro / USM Pro Max root filesystem is an **overlayfs** — a union of two layers:

```
/boot/firmware/rootfs  →  squashfs (read-only, replaced on firmware update)
/mnt/.rwfs             →  ext4 (writable upper layer, changes go here)
/                      →  overlayfs union of the two above
```

When you install a package or edit a file, the change is written to the writable upper layer at `/mnt/.rwfs/data/`. Reads see the union: upper layer takes precedence, squashfs fills in everything else.

There are also two **completely separate partitions** that firmware updates never touch:

| Path | Device | Contents |
|------|--------|----------|
| `/data/` | overlayfs upper layer (`/mnt/.rwfs/data/data/`) | User/app persistent data — Ubiquiti explicitly preserves this path |
| `/persistent/` | separate ext4 partition (`/dev/disk/by-partlabel/persistent`) | Ubiquiti's internal dpkg rescue cache and system state |

#### Why Firmware Updates Break Samba

Firmware updates replace the squashfs (lower layer). Packages installed via `apt` (like Samba) live in the upper layer — but when the new squashfs boots, it carries a fresh dpkg database with no knowledge of those packages. The dpkg rescue process then purges unrecognized packages from the upper layer, removing the Samba binaries. Config files edited in `/etc/` get similarly cleaned up.

The `/data/` path in the upper layer is **not** cleaned — Ubiquiti explicitly preserves it for user data. This is why your backup sparsebundles in `/volume1/timemachine/` survive (separate disk) and why scripts stored in `/data/timemachine/` survive.

#### The Native Ubiquiti Hook System

Rather than using a community workaround, this setup hooks into Ubiquiti's own boot infrastructure. Inspecting the squashfs directly revealed:

```
/lib/systemd/system/bootup-bottom-invoke.service  →  runs on every boot (in squashfs, permanent)
    └── ExecStart: /usr/sbin/bootup-invoker bottom
        └── calls: /usr/sbin/hook-invoker /usr/lib/ubnt/hooks/system/bootup-bottom/ '{}'
            └── executes every script in that directory, sorted by filename
```

`bootup-bottom-invoke.service` is baked into the squashfs and will always be present regardless of firmware version. `hook-invoker` is a simple Python script that runs all executables in the given directory.

The hook directory `/usr/lib/ubnt/hooks/system/bootup-bottom/` sits in the overlayfs upper layer. Unlike Samba, scripts dropped there manually are **not tracked by dpkg**, so the dpkg cleanup process after a firmware update leaves them alone. They persist.

#### The Two-Layer Design

```
/usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh   ← tiny wrapper (overlayfs upper, not dpkg-managed)
    └── exec /data/timemachine/99-timemachine.sh              ← actual script (/data/, explicitly preserved)
```

- **Layer 1 (hook wrapper):** not dpkg-managed, survives overlayfs cleanup
- **Layer 2 (actual script):** in `/data/timemachine/`, which Ubiquiti explicitly preserves
- **Self-healing:** the actual script checks on every run whether the hook wrapper exists and recreates it if not, so even if Layer 1 is somehow lost, one manual run restores it permanently

The result: after any firmware update, on the first reboot, the hook runs, detects missing packages, reinstalls Samba and Avahi via `apt`, restores configs from `/data/timemachine/`, and starts the services — automatically, with no user intervention.

### Keeping the Backup Current

If you ever change your Samba config or Samba password, update the backups:

```bash
# After changing smb.conf
cp /etc/samba/smb.conf /data/timemachine/smb.conf.bak  # optional full backup
# Manually update /data/timemachine/smb-timemachine.conf if the [TimeMachine] block changed

# After changing the timemachine Samba password
cp /var/lib/samba/private/passdb.tdb /data/timemachine/passdb.tdb
```

---

## Multiple Mac Support

**Yes, this configuration fully supports multiple Macs backing up simultaneously!**

### How It Works

- Each Mac creates its own separate backup folder within `/volume1/timemachine/`
- The folder is named after your Mac's hostname (e.g., "MacBook-Pro 2025-11-29-195534")
- Time Machine uses locking mechanisms to prevent conflicts
- All available disk space is shared across all Macs (Time Machine manages space automatically)
- Each Mac maintains completely independent backups with separate sparsebundle files

### Adding Additional Macs

For each additional Mac, simply:

1. Connect to `smb://timemachine@192.168.1.1/TimeMachine`
2. Use the same credentials (username: `timemachine`, password: `timemachine`)
3. Add it as a Time Machine destination

All Macs can use the same Samba user account. Time Machine automatically handles separation of backups.

### Monitoring Multiple Mac Backups

On the UDM Pro, you can see all Mac backups:

```bash
ssh root@192.168.1.1
ls -lh /volume1/timemachine/
```

You'll see a directory for each Mac that has backed up to this share.

## After Firmware Updates

**UDM Pro and USM Pro Max firmware updates wipe all apt-installed packages**, including Samba and Avahi. After any firmware update, Time Machine backups will stop working until the software is reinstalled.

Your backup data on `/volume1/timemachine` is safe — only the software is removed, not the disk contents.

**If you completed [Step 8](#step-8-automate-recovery-after-firmware-updates)**, the boot script handles this automatically on the next reboot — no manual intervention needed.

**If you haven't set up the boot script**, see the [Troubleshooting](#issue-time-machine-stops-working-after-firmware-update) section for the manual recovery procedure, then consider going back and completing Step 8.

---

## Monitoring and Maintenance

### Check Backup Progress

On your Mac:
- Open **System Settings > General > Time Machine**
- You'll see the progress bar and estimated time remaining

On the UDM Pro:

```bash
# Check disk usage
du -sh /volume1/timemachine/*

# Monitor in real-time (while backing up)
watch -n 5 'du -sh /volume1/timemachine/*'
```

### Verify Backup Integrity

On your Mac:

```bash
# List all backups
tmutil listbackups

# Verify latest backup
tmutil verifychecksums /Volumes/TimeMachine
```

## Troubleshooting

### Issue: "The selected network backup disk does not allow reading, writing and appending"

**Solution**: This is a permissions issue. Ensure:

1. The directory has proper ownership:
   ```bash
   chown -R timemachine:timemachine /volume1/timemachine
   chmod 777 /volume1/timemachine
   ```

2. You're connecting with the `timemachine` user (not as Guest)

3. Restart Samba after any configuration changes:
   ```bash
   systemctl restart smbd nmbd
   ```

### Issue: "Time Machine couldn't back up to UDM-PRO-MAX.local"

**Possible causes and solutions**:

1. **Guest access**: Don't connect as Guest. Always use the `timemachine` user credentials.

2. **Incomplete backups**: Clean up any incomplete backup folders:
   ```bash
   rm -rf /volume1/timemachine/*.incomplete
   ```

3. **Check Samba logs** for specific errors:
   ```bash
   tail -100 /var/log/samba/log.smbd
   ```

4. **Verify the configuration** is loaded:
   ```bash
   testparm -s | grep -A 20 TimeMachine
   ```

### Issue: Mac Can't Find Time Machine Share

**Solution**:

1. Verify Avahi is running:
   ```bash
   ps aux | grep avahi-daemon
   ```

2. Manually connect using Finder (⌘+K):
   ```
   smb://192.168.1.1/TimeMachine
   ```

3. Check firewall rules aren't blocking SMB (port 445) or mDNS (port 5353)

### Issue: Backup is Very Slow

**Tips for better performance**:

1. **First backup is always slow**: It's copying everything. Subsequent backups are incremental and much faster.

2. **Use wired connection**: If possible, connect your Mac to the network via Ethernet instead of Wi-Fi.

3. **Check network congestion**: Large backups can saturate your network.

4. **Verify disk health** on UDM Pro:
   ```bash
   smartctl -a /dev/md3
   ```

### Issue: Out of Space on UDM Pro

Time Machine should respect the available space, but you can manually check:

```bash
# Check space used
du -sh /volume1/timemachine

# Check available space
df -h /volume1
```

If you need more space, you can delete old backups from your Mac:
- Open **System Settings > General > Time Machine**
- Click the info icon next to your backup
- Select old backups and delete them

### Issue: Error Code 49 - "Could not create local snapshot"

**This is the most common issue** - it means your **Mac's internal drive is too full**.

Time Machine needs to create local APFS snapshots on your Mac before backing up. If your Mac doesn't have enough free space (typically needs at least 20-30GB free), you'll get error code 49.

**Solution: Free up disk space on your Mac**

1. **Check your Mac's available space**:
   ```bash
   df -h /
   diskutil apfs list | grep -A 5 "Container"
   ```

2. **Identify what's using space**:
   ```bash
   # Check home directory usage
   du -sh ~/* ~/.* 2>/dev/null | sort -hr | head -20

   # Check Library (often the biggest culprit)
   du -sh ~/Library/* 2>/dev/null | sort -hr | head -10
   ```

3. **Common space hogs and how to clean them**:

   **Docker (often 30-50GB!)**
   ```bash
   docker system prune -a --volumes -f
   ```

   **Development Caches (10-20GB)**
   ```bash
   # Homebrew cache
   rm -rf ~/Library/Caches/Homebrew/*
   brew cleanup -s

   # npm cache
   npm cache clean --force
   rm -rf ~/.npm

   # Go cache
   go clean -cache -modcache
   rm -rf ~/Library/Caches/go-build/*

   # Python cache
   rm -rf ~/Library/Caches/com.apple.python/*

   # Playwright browsers
   rm -rf ~/Library/Caches/ms-playwright/*
   ```

   **General Caches**
   ```bash
   rm -rf ~/.cache/*
   rm -rf ~/Library/Caches/Google/*
   rm -rf ~/Library/Caches/com.spotify.client/*
   ```

   **Downloads folder**
   ```bash
   # Check what's in there first
   ls -lhS ~/Downloads | head -20
   # Then delete old files manually
   ```

4. **After freeing up space, retry the backup**:
   ```bash
   tmutil startbackup
   ```

**Expected result**: After freeing 20-30GB, Time Machine should successfully create snapshots and start backing up.

### Issue: Error Code 50 - "The backup disk is not available"

Error code 50 can indicate several issues:

1. **ARM/aarch64 Architecture Bug**: If your UDM Pro uses ARM architecture (aarch64), the `fruit:time machine max size` parameter is broken and causes failures.

   **Check your architecture**:
   ```bash
   ssh root@192.168.1.1 "uname -m"
   ```

   If it returns `aarch64`, **remove this line from your Samba config**:
   ```bash
   ssh root@192.168.1.1 "sed -i '/fruit:time machine max size/d' /etc/samba/smb.conf"
   ssh root@192.168.1.1 "systemctl restart smbd nmbd"
   ```

2. **Permissions issues**: Verify the timemachine user can write to the directory
3. **Network connectivity**: Check if the SMB share is accessible
4. **Corrupted sparsebundle**: May need to start fresh (see below)

### Issue: Backup Keeps Failing with Multiple Interrupted Attempts

If you see many `.interrupted` or `.inprogress` backup folders, Time Machine is failing repeatedly.

**Solution: Clean up and start fresh**

1. **Check for interrupted backups**:
   ```bash
   # On your Mac (if mounted)
   ls -la "/Volumes/Backups of <hostname>/" | grep interrupted

   # Or on UDM Pro
   ssh root@192.168.1.1 "ls -lah /volume1/timemachine/"
   ```

2. **Delete interrupted backups** (on UDM Pro):
   ```bash
   ssh root@192.168.1.1 "rm -rf /volume1/timemachine/*.interrupted"
   ssh root@192.168.1.1 "rm -rf '/volume1/timemachine/*.inprogress'"
   ```

3. **If backups continue to fail, start with a fresh sparsebundle**:
   ```bash
   # Stop any running backup
   tmutil stopbackup

   # On UDM Pro, rename the old sparsebundle
   ssh root@192.168.1.1 "mv /volume1/timemachine/<hostname>.sparsebundle /volume1/timemachine/<hostname>.sparsebundle.old"

   # Start a new backup - Time Machine will create a fresh sparsebundle
   tmutil startbackup
   ```

### Issue: Time Machine Stops Working After Firmware Update

**This is expected behavior.** UDM Pro and USM Pro Max firmware updates wipe all packages installed via `apt`, including Samba and Avahi. Your backup data on `/volume1/timemachine` is preserved — only the software needs to be reinstalled.

**Full recovery procedure:**

1. **Reinstall packages**:
   ```bash
   ssh root@192.168.1.1
   apt update && apt install -y samba avahi-daemon
   ```

2. **Re-add the TimeMachine share to `/etc/samba/smb.conf`** (the `[TimeMachine]` section from Step 4 will be gone — re-run that step).

3. **Re-add the Samba user password** (the OS user survives but the Samba password database is wiped):
   ```bash
   printf 'timemachine\ntimemachine\n' | smbpasswd -a -s timemachine
   smbpasswd -e timemachine
   ```

4. **Restore the Avahi service file** (re-run Step 5).

5. **Start services**:
   ```bash
   systemctl restart smbd nmbd
   # Avahi may already be running — reload it instead of restarting
   kill -HUP $(cat /var/run/avahi-daemon/pid)
   ```

6. **Start a backup from your Mac**:
   ```bash
   sudo tmutil startbackup
   ```

**Tip**: After each firmware update, check `systemctl status smbd` before assuming there's a more complex problem — a missing package is almost always the cause.

---

## Security Considerations

### Current Setup

- Uses authenticated access (timemachine user)
- Not encrypted over the network (standard SMB)
- All Macs share the same credentials

### Hardening Options

1. **Use unique credentials per Mac**:
   ```bash
   # Create user for each Mac
   useradd -M -s /usr/sbin/nologin macbook-pro
   printf 'strong-password\nstrong-password\n' | smbpasswd -a -s macbook-pro
   smbpasswd -e macbook-pro
   ```

   Then update `smb.conf` to use:
   ```
   valid users = timemachine, macbook-pro, macbook-air
   ```

2. **Restrict by IP address**: Add to the `[TimeMachine]` section:
   ```
   hosts allow = 192.168.1.0/24
   ```

3. **Enable SMB signing** (in `[global]` section):
   ```
   server signing = mandatory
   ```

## Performance Tuning

For better performance, you can add these options to the `[TimeMachine]` section:

```
# Increase socket options (in [global] section)
socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072

# Disable strict locking (in [TimeMachine] section)
strict locking = no

# Increase async read/write sizes
read raw = yes
write raw = yes
```

**Note**: Test these changes carefully as they may impact reliability.

## Backup Best Practices

1. **Monitor disk space regularly**: Don't let the disk fill completely
2. **Test restores periodically**: Ensure you can actually recover files
3. **Keep multiple backups**: Consider an additional backup destination
4. **Document your setup**: Keep this guide and your specific settings noted
5. **Update regularly**: Keep UDM Pro firmware and macOS updated

## Uninstalling / Reverting

To remove the Time Machine configuration:

1. **On each Mac**: Remove the Time Machine destination in System Settings

2. **On UDM Pro**:
   ```bash
   # Remove Samba configuration
   sed -i '/^\[TimeMachine\]/,/^fruit:delete_empty_adfiles/d' /etc/samba/smb.conf

   # Remove Avahi service
   rm /etc/avahi/services/smb.service

   # Restart services
   systemctl restart smbd nmbd
   kill -HUP $(cat /var/run/avahi-daemon/pid)

   # Optionally remove data (BE CAREFUL!)
   # rm -rf /volume1/timemachine
   ```

## Summary

You now have a fully functional Time Machine backup server on your UDM Pro or USM Pro Max that:

- ✅ Supports multiple Macs simultaneously
- ✅ Uses authenticated access for security
- ✅ Automatically appears in Time Machine preferences
- ✅ Provides massive backup space (16TB on UDM Pro, 14.5TB on USM Pro Max with RAID-1)
- ✅ Maintains separate backups for each Mac
- ✅ Works with all modern macOS versions
- ✅ ARM-optimized Samba configuration for maximum stability
- ✅ (USM Pro Max) RAID-1 redundancy protects against disk failure

Each Mac will create and maintain its own backup folder, and Time Machine handles all the complexity of keeping backups separate and preventing conflicts.

## Credits and Resources

- [Samba VFS Fruit Module Documentation](https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html)
- [Apple Time Machine SMB Specification](https://developer.apple.com/documentation/)
- [Avahi mDNS Documentation](https://www.avahi.org/)

## Tested Configuration

This guide was created and tested with the following versions:

### UDM Pro Environment
- **Firmware Version**: UDMPRO.al324.v4.4.6.44eadbd.251020.1723
- **OS**: Debian GNU/Linux 11 (bullseye)
- **Architecture**: aarch64 (ARM64)
- **Samba Version**: 4.13.13-Debian
- **Avahi Version**: 0.8
- **Disk**: 16TB drive mounted at `/volume1` (RAID configuration via `/dev/md3`)

### USM Pro Max Environment
- **OS**: Debian GNU/Linux 11 (bullseye)
- **Architecture**: aarch64 (ARM64)
- **Samba Version**: 4.13.13+dfsg-1~deb11u7
- **Avahi Version**: 0.8-5+deb11u3
- **Disk**: Dual 14.6TB disks in RAID-1 via mdadm (14.5TB usable)
- **RAID Device**: `/dev/md3` (sdb5 + sdc5)
- **RAID Status**: Both disks active [UU] for full redundancy

### macOS Environment
- **Tested macOS Version**: macOS 26.1 (Build 25B78)
- **Compatibility**: Should work with macOS 10.15 (Catalina) and later
- **Tested with**: Multiple MacBook Pros and MacBook Airs backing up simultaneously

### Network Setup
- **Protocol**: SMB (Samba)
- **Discovery**: Avahi mDNS
- **Authentication**: Samba user authentication (not guest access)
- **Stability Features**: ARM-optimized configuration without problematic fruit:time machine max size parameter

---

**Last Updated**: January 10, 2026

If you found this guide helpful, please share it with others who might benefit from using their UDM Pro or USM Pro Max as a Time Machine backup destination!

## Support

If you found this guide useful and would like to support my work, consider buying me a coffee!

[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/scttfrdmn)
