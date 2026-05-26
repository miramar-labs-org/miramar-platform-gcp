# Shared Folder (DGX ↔ WSL2)

The DGX Spark exposes a Samba share used to pass intermediate artifacts
(checkpoints, embeddings, datasets, etc.) between the `dgx` and `wsl2`
runners during training workflows.

| Machine | Path |
|---|---|
| DGX | `/home/aaron/shared` |
| WSL2 (Ubuntu) | `/home/aaron/shared` |
| Windows | `\\spark-79b7.local\shared` |

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
mkdir -p /home/aaron/shared
```

### 3. Back up and edit smb.conf

```sh
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
sudo nano /etc/samba/smb.conf
```

Append at the end:

```ini
[shared]
   path = /home/aaron/shared
   browseable = yes
   read only = no
   writable = yes
   valid users = aaron
   force user = aaron
   create mask = 0660
   directory mask = 0770
```

### 4. Add aaron to Samba's password database

```sh
sudo smbpasswd -a aaron
sudo smbpasswd -e aaron
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

WSL2 distros use **smbclient** to access individual files from the DGX share — no CIFS kernel
mount required. Credentials are stored in `~/.smbcredentials` (baked into the template by
`bootstrap.sh`; the password is the DGX Samba password set with `smbpasswd`).

### Install smbclient

`smbclient` is pre-installed in the template by `bootstrap.sh`. To install manually:

```sh
sudo apt-get install -y --no-install-recommends smbclient
```

### Ad-hoc file access

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

### Optional: CIFS kernel mount (ad-hoc / manual only)

A CIFS mount gives a familiar filesystem view but requires `cifs-utils` and sudo.
It is **not set up automatically** by any workflow — use it for manual troubleshooting only.

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

Sign in with username `aaron` and the Samba password. To map as a drive
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
sudo mount -t cifs //192.168.x.x/shared /home/aaron/shared \
  -o username=aaron,uid=$(id -u),gid=$(id -g),vers=3.0
```

**Check Samba status on DGX:**

```sh
sudo systemctl status smbd
sudo journalctl -u smbd -n 50 --no-pager
testparm
```
