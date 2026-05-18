# My WSL Image Configs

## Create WSL base image:

        wsl --update

        wsl --install -d Ubuntu-22.04

## GPU (only if you want NVIDIA containers)

Install the latest NVIDIA Windows driver that supports WSL2 CUDA. NVIDIA’s WSL guide emphasizes: install the Windows driver only (don’t install a Linux display driver inside WSL).
[NVIDIA Docs](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)

[v591.44](https://www.nvidia.com/en-us/drivers/details/258748/)

After driver install, inside WSL you should eventually be able to run:

    nvidia-smi

## Enable passwordless sudo in distro

    sudo visudo -f /etc/sudoers.d/aaron

add:

    aaron ALL=(ALL) NOPASSWD: ALL

Create `/etc/wsl.conf`:

    [boot]
    systemd=true
    [user]
    default=aaron
    [interop]
    appendWindowsPath=false


Copy `bootstrap.sh` into distro $HOME, then:

    chmod +x bootstrap.sh


## Back in PowerShell:

    wsl --shutdown

## Export 'golden image':

    wsl --shutdown
    wsl --list --verbose
    mkdir C:\wsl-templates -Force
    
    wsl --export Ubuntu-22.04 C:\wsl-templates\ubuntu-22.04-base-template.tar

## Import fresh copy from snapshot:

    mkdir C:\wsl\Ubuntu2204-Base -Force
    wsl --import Ubuntu2204-Base C:\wsl\Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-base-template.tar --version 2
    wsl -d Ubuntu2204-Base --cd ~

Run bootsrtap.sh:

    bootstrap.sh

Restart Ubuntu2024-Base to manually configure p10k:

    wsl --shutdown
    wsl -d Ubuntu2204-Base --cd ~

Distro is now configured. We now snapshot this 'configured' instance too:

    wsl --shutdown
    wsl --export Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-configured-template.tar

Cleanup:

    wsl --unregister Ubuntu-22.04
    wsl --unregister Ubuntu2204-Base

Finally, bring up a fresh configured instance :

    wsl --import Ubuntu2204-Dev1 C:\wsl\Ubuntu2204-Dev1 C:\wsl-templates\ubuntu-22.04-configured-template.tar --version 2
    wsl -d Ubuntu2204-Dev1 --cd ~
    