# Shared Folder (DGX ↔ WSL2)

The DGX Spark exposes a Samba share used to pass intermediate artifacts
(checkpoints, embeddings, datasets, etc.) between the `dgx` and `wsl2`
runners during training workflows.

| Machine       | Path                        |
| ------------- | --------------------------- |
| DGX           | `~/shared`                  |
| WSL2 (Ubuntu) | `~/shared`                  |
| Windows       | `\\spark-79b7.local\shared` |

---

## DGX setup (Samba server)

The DGX acts as the SMB file server. These steps were run once on the DGX.

### 1. Install Samba

```sh
sudo apt update
sudo apt install samba
```

### 2. Create the shared folder

```sh
mkdir -p ~/shared
```

### 3. Back up and edit smb.conf

```sh
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
sudo nano /etc/samba/smb.conf
```

Append at the end (replace `$USER` with your Linux username — smb.conf does not expand shell variables):

```ini
[shared]
   path = /home/$USER/shared
   browseable = yes
   read only = no
   writable = yes
   valid users = $USER
   force user = $USER
   create mask = 0660
   directory mask = 0770
```

### 4. Add your user to Samba's password database

```sh
sudo smbpasswd -a "$USER"
sudo smbpasswd -e "$USER"
```

### 5. Validate config and restart

```sh
testparm
sudo systemctl restart smbd nmbd
sudo systemctl enable smbd nmbd
```

### 6. Allow Samba through the firewall

```sh
sudo ufw allow samba
```

---

## Accessing the share from WSL2

WSL2 distros provisioned via **WSL2 Provision** use `~/shared/` for the
shared store. `setup-shared-ssh.sh` mounts it during `firstboot.sh`, the
`mount-dgx-shared.service` / `mount-dgx-shared.timer` pair keeps it available
after normal boots, and the `wsl2-<name>` SSH ProxyCommand runs the mount helper
again before execing `sshd -i` on cold starts.

Do not mount the shared folder from WSL2 `/etc/fstab`; `/etc/wsl.conf` keeps
`mountFsTab=false`. To remount manually:

```sh
sudo /usr/local/sbin/mount-dgx-shared.sh
```

Credentials are stored in `~/.smbcredentials` (baked into the template
by `rebuild-template.ps1`).

### Ad-hoc file access via smbclient

For scripts that don't need a mounted filesystem, `smbclient` is available:

```sh
# List share contents
smbclient //spark-79b7.local/shared -A ~/.smbcredentials -N -c "ls"

# Download a file
smbclient //spark-79b7.local/shared -A ~/.smbcredentials -N \
  -c "get path/to/file /local/destination"

# Upload a file
smbclient //spark-79b7.local/shared -A ~/.smbcredentials -N \
  -c "put /local/file remote/path/file"
```

### Manual CIFS mount (if not provisioned via workflow)

```sh
sudo apt-get install -y cifs-utils
mkdir -p ~/shared
sudo mount -t cifs //spark-79b7.local/shared ~/shared \
  -o credentials=$HOME/.smbcredentials,uid=$(id -u),gid=$(id -g),vers=3.0
```

Unmount when done:

```sh
sudo umount ~/shared
```

---

## Windows access

In File Explorer address bar:

```
\\spark-79b7.local\shared
```

Sign in with your Samba username and the Samba password. To map as a drive
letter: right-click **This PC** → **Map network drive**, enter the path
above, check **Reconnect at sign-in**.

If hostname resolution fails, use the DGX's LAN IP directly:

```sh
# on DGX
hostname -I
```

---

## Troubleshooting

**Windows prompts for credentials repeatedly** — clear cached credentials in
Control Panel → Credential Manager → Windows Credentials, remove any entry
for the DGX, then reconnect.

**Mount fails in WSL2** — test with the IP instead of hostname:

```sh
sudo mount -t cifs //192.168.x.x/shared ~/shared \
  -o username="$USER",uid=$(id -u),gid=$(id -g),vers=3.0
```

**Check Samba status on DGX:**

```sh
sudo systemctl status smbd
sudo journalctl -u smbd -n 50 --no-pager
testparm
```
