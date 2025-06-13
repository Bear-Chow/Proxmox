In short:
LXC is powerful and lightweight, but for full compatibility, easier troubleshooting, and maximum security, VMs are the official recommendation.

    Isolation: VMs provide full kernel and system isolation, while LXC containers share the host kernel. This means a security or kernel bug in the host or container can potentially affect other containers or the host itself.
    Systemd and Privileged Operations: Nextcloud (and some of its apps/upgrades) may expect full access to system features (kernel modules, systemd, FUSE, certain mounts) not always available or reliable in LXC.
    App Armor/Security Modules: Some Nextcloud features (like external storage, preview generation, or advanced file operations) require kernel capabilities often restricted in LXC.
    Snap/Upgrade/Backup Tools: Nextcloud’s snap package and some backup solutions expect a regular OS, not a container.
    Vendor Support: Many software vendors (including Nextcloud, Collabora, OnlyOffice, etc.) only test and support their software in VMs or bare metal, not LXC, because it’s the lowest-common-denominator.
    Updates and Recovery: With a VM you can easily snapshot, rollback, and recover the entire system with all its kernel and system state—harder and less reliable with LXC.

Just be aware:

    Some advanced Nextcloud features or apps may not work out-of-the-box.
    If you hit a “not supported on LXC” warning in Nextcloud, it’s not a bug in your setup.
    For production or business-critical use, prefer a VM or follow Nextcloud’s support recommendations.

Summary:

    Official = VM for broadest compatibility and support.
    LXC = lightweight, works for many, but “DIY” and not officially supported.
    
