# Windows 11 OpenSSH Server — Setup for DGX/Linux/GHA Access

Tested topology:

```text
DGX/Linux:    192.168.1.200
Windows 11:   192.168.1.201
Windows user: aaron
SSH port:     22
```

---

## 1. Install OpenSSH Server

Open **PowerShell as Administrator** on the Windows laptop.

Check whether OpenSSH Server is installed:

```powershell
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
```

If `State : NotPresent`, install it:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

Verify:

```powershell
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
# Expected: State : Installed
```

---

## 2. Start and enable the SSH server

```powershell
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Verify:

```powershell
Get-Service sshd | Select-Object Name, Status, StartType
```

Expected:

```text
Name  Status   StartType
----  ------   ---------
sshd  Running  Automatic
```

---

## 3. Set PowerShell as the default SSH shell

Required for GHA workflows — without this, SSH sessions land in `cmd.exe` and backslash-heavy PowerShell commands behave incorrectly.

```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
  -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -PropertyType String -Force

Restart-Service sshd
```

---

## 4. Set the Windows network profile to Private

**This was required.** If Wi-Fi is set to `Public`, inbound SSH silently times out from the DGX even though ping works and `sshd` is running.

Find the correct adapter name first:

```powershell
Get-NetConnectionProfile
# Note the InterfaceAlias value — e.g. "Wi-Fi", "Wi-Fi 2", "Ethernet"
```

Then set it to Private:

```powershell
Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Private
```

Verify:

```powershell
Get-NetConnectionProfile
# Expected: NetworkCategory : Private
```

---

## 5. Verify or create the Windows Firewall rule

Installing OpenSSH Server usually creates the rule automatically. Verify:

```powershell
Get-NetFirewallRule -Name *OpenSSH* | Select-Object DisplayName, Enabled, Direction, Action
```

Expected:

```text
DisplayName                  Enabled  Direction  Action
-----------                  -------  ---------  ------
OpenSSH SSH Server (sshd)    True     Inbound    Allow
```

If no enabled inbound rule appears, create one:

```powershell
New-NetFirewallRule `
  -Name sshd `
  -DisplayName 'OpenSSH SSH Server' `
  -Enabled True `
  -Direction Inbound `
  -Protocol TCP `
  -Action Allow `
  -LocalPort 22
```

---

## 6. Confirm Windows is listening on port 22

```powershell
Get-NetTCPConnection -LocalPort 22 -State Listen
```

Expected:

```text
LocalAddress  LocalPort  State
0.0.0.0       22         Listen
::            22         Listen
```

Test locally:

```powershell
Test-NetConnection 127.0.0.1 -Port 22
Test-NetConnection 192.168.1.201 -Port 22
# Expected: TcpTestSucceeded : True
```

---

## 7. Test TCP connectivity from the DGX

```bash
nc -vz -w 5 192.168.1.201 22
# Expected: Connection to 192.168.1.201 22 port [tcp/ssh] succeeded!
```

If `nc` is missing:

```bash
sudo apt install -y netcat-openbsd
```

---

## 8. Test password-based SSH

```bash
ssh aaron@192.168.1.201
```

Accept the host key if prompted, then enter the Windows password. If this works, proceed to passwordless setup.

---

# Passwordless SSH

## 9. Admin user key file — critical gotcha

If `aaron` is a local Administrator, Windows OpenSSH **ignores** `C:\Users\aaron\.ssh\authorized_keys` and requires the key here instead:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

## 10. Create or verify the SSH key on the Linux machine

```bash
ls -l ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

If it doesn't exist:

```bash
ssh-keygen -t ed25519 -C "dgx-to-win11-aaron"
# Leave passphrase empty for passwordless access
```

Print the public key to copy:

```bash
cat ~/.ssh/id_ed25519.pub
```

## 11. Add the public key on Windows (admin user)

On Windows, open **PowerShell as Administrator**:

```powershell
New-Item -ItemType File -Path "C:\ProgramData\ssh\administrators_authorized_keys" -Force
notepad "C:\ProgramData\ssh\administrators_authorized_keys"
```

Paste the public key as a single line. Save and close.

Fix permissions (required — OpenSSH rejects the file if permissions are too open):

```powershell
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /grant "Administrators:F" /grant "SYSTEM:F"
```

Restart sshd:

```powershell
Restart-Service sshd
```

## 12. Test public-key SSH

```bash
ssh -i ~/.ssh/id_ed25519 aaron@192.168.1.201
```

Verbose debug if needed:

```bash
ssh -vvv -i ~/.ssh/id_ed25519 -o PreferredAuthentications=publickey aaron@192.168.1.201
# Look for: Server accepts key
```

## 13. Optional: SSH alias on the Linux machine

```bash
# ~/.ssh/config
Host win11
    HostName 192.168.1.201
    User aaron
    IdentityFile ~/.ssh/id_ed25519
```

```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/config ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub
ssh win11
```

---

# Copy files with SCP

```bash
# DGX → Windows
scp your-file.zip win11:/C:/Users/aaron/Downloads/

# Windows → DGX (run from Windows PowerShell)
scp C:\path\to\your-file.zip aaron@192.168.1.200:/home/aaron/
```

---

# Troubleshooting

## Ping works but SSH hangs or times out

1. Confirm network profile is `Private` (step 4 — most common cause)
2. Confirm firewall allows OpenSSH inbound (step 5)
3. Confirm `sshd` is running
4. Confirm Windows is listening on `0.0.0.0:22` (step 6)
5. Check for router/AP client isolation, VPNs, or third-party security software

## SSH still asks for a password

```bash
ssh -vvv -o PreferredAuthentications=publickey aaron@192.168.1.201
# Look for: Offering public key ... then Authenticated
```

If the key is offered but rejected:

1. Confirm `aaron` is an Administrator — if so, the key must be in `C:\ProgramData\ssh\administrators_authorized_keys` (not the home dir)
2. Confirm permissions are correct:
   ```powershell
   icacls "C:\ProgramData\ssh\administrators_authorized_keys"
   # Must show only: Administrators, SYSTEM
   ```

## GHA workflow SSH commands behave incorrectly

Confirm PowerShell is set as the default SSH shell (step 3). Without it, the session runs in `cmd.exe` and path/quoting handling differs.

---

# Quick reference

## Windows Admin PowerShell

```powershell
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Get-NetConnectionProfile                                          # find adapter name
Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Private
Get-NetFirewallRule -Name *OpenSSH* | Select-Object DisplayName, Enabled, Direction, Action
Get-NetTCPConnection -LocalPort 22 -State Listen
Restart-Service sshd
```

## DGX/Linux

```bash
nc -vz -w 5 192.168.1.201 22
ssh aaron@192.168.1.201
ssh -i ~/.ssh/id_ed25519 aaron@192.168.1.201
```
