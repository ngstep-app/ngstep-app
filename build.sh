#!/bin/sh
set -e

# === Configuration ===
DIST="excalibur"
MIRROR="http://deb.devuan.org/merged"
ARCH="amd64"
WORK="$(pwd)/work"
ISO_NAME="ngstep-app-$(date +%Y.%m.%d)-${ARCH}.iso"

# === Clean previous build ===
rm -rf "${WORK}"
mkdir -p "${WORK}"

# === Step 1: Bootstrap minimal Devuan root filesystem ===
echo "==> Bootstrapping ${DIST} root filesystem..."
debootstrap --arch="${ARCH}" --variant=minbase "${DIST}" "${WORK}/rootfs" "${MIRROR}"

# === Step 2: Configure apt sources inside rootfs ===
cat > "${WORK}/rootfs/etc/apt/sources.list" << EOF
deb ${MIRROR} ${DIST} main non-free-firmware
deb ${MIRROR} ${DIST}-security main non-free-firmware
deb ${MIRROR} ${DIST}-updates main non-free-firmware
deb ${MIRROR} ${DIST}-backports main non-free-firmware
EOF

# === Step 2b: Add XLibre repository ===
echo "==> Adding XLibre repository..."

# Mount required filesystems for chroot
mount --bind /dev "${WORK}/rootfs/dev"
mount --bind /dev/pts "${WORK}/rootfs/dev/pts"
mount -t proc proc "${WORK}/rootfs/proc"
mount -t sysfs sysfs "${WORK}/rootfs/sys"

# Prevent services from starting during install
cat > "${WORK}/rootfs/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${WORK}/rootfs/usr/sbin/policy-rc.d"

# Install gnupg and curl to fetch and dearmor the XLibre key
chroot "${WORK}/rootfs" /bin/sh -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends gnupg curl ca-certificates
"

# Add XLibre GPG key
curl -fsSL https://mrchicken.nexussfan.cz/publickey.asc | \
    chroot "${WORK}/rootfs" gpg --dearmor -o /usr/share/keyrings/NexusSfan.pgp
chmod a+r "${WORK}/rootfs/usr/share/keyrings/NexusSfan.pgp"

# Add XLibre sources
cat > "${WORK}/rootfs/etc/apt/sources.list.d/xlibre-debian.sources" << 'EOF'
Types: deb
URIs: https://xlibre-debian.github.io/devuan/
Suites: main
Components: stable
Signed-By: /usr/share/keyrings/NexusSfan.pgp
EOF

# === Step 3: Chroot and install packages ===
echo "==> Installing packages..."

# Read package list (strip comments and blank lines)
PACKAGES=$(grep -v '^#' packages.list | grep -v '^$' | tr '\n' ' ')

chroot "${WORK}/rootfs" /bin/sh -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ${PACKAGES}
    apt-get clean
    rm -rf /var/lib/apt/lists/*
"

# === Step 3b: Install Gershwin ===
echo "==> Installing Gershwin..."

chroot "${WORK}/rootfs" /bin/sh -c "
    git clone https://github.com/ngstep-app/gershwin-developer.git /Developer
    /Developer/Library/Scripts/Bootstrap.sh
    /Developer/Library/Scripts/Checkout.sh
    cd /Developer && make install
"

# Enable Gershwin services for sysvinit
chroot "${WORK}/rootfs" update-rc.d dshelper defaults
chroot "${WORK}/rootfs" update-rc.d loginwindow defaults

# Initialize directory services database
chroot "${WORK}/rootfs" /System/Library/Tools/dscli init

# Final cleanup before squashfs
chroot "${WORK}/rootfs" /bin/sh -c "
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/* /var/tmp/*
"

# Remove policy-rc.d
rm -f "${WORK}/rootfs/usr/sbin/policy-rc.d"

# Unmount chroot filesystems
umount "${WORK}/rootfs/sys" 2>/dev/null || true
umount "${WORK}/rootfs/proc" 2>/dev/null || true
umount "${WORK}/rootfs/dev/pts" 2>/dev/null || true
umount "${WORK}/rootfs/dev" 2>/dev/null || true

# === Step 4: Create squashfs ===
echo "==> Creating squashfs..."
mkdir -p "${WORK}/iso/live"

# Copy kernel and initrd to iso
cp "${WORK}/rootfs/boot/vmlinuz-"* "${WORK}/iso/live/vmlinuz"
cp "${WORK}/rootfs/boot/initrd.img-"* "${WORK}/iso/live/initrd.img"

# Create squashfs (excluding boot images to save space)
mksquashfs "${WORK}/rootfs" "${WORK}/iso/live/filesystem.squashfs" \
    -comp xz -e boot/vmlinuz-* -e boot/initrd.img-*

# === Step 5: Setup GRUB for BIOS + UEFI ===
echo "==> Setting up GRUB..."

# Copy grub.cfg
mkdir -p "${WORK}/iso/boot/grub"
cp grub.cfg "${WORK}/iso/boot/grub/grub.cfg"

# Create BIOS GRUB image
grub-mkstandalone \
    --format=i386-pc \
    --output="${WORK}/bios.img" \
    --install-modules="linux normal iso9660 biosdisk memdisk search tar ls all_video font gfxterm part_gpt part_msdos" \
    --modules="linux normal iso9660 biosdisk search part_gpt part_msdos" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${WORK}/iso/boot/grub/grub.cfg"

# Create BIOS boot image (cdboot + core)
cat /usr/lib/grub/i386-pc/cdboot.img "${WORK}/bios.img" > "${WORK}/iso/boot/grub/bios.img"

# Create UEFI GRUB image
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${WORK}/bootx64.efi" \
    --install-modules="linux normal iso9660 search tar ls all_video font gfxterm part_gpt part_msdos fat efi_gop efi_uga" \
    --modules="linux normal iso9660 search part_gpt part_msdos fat efi_gop" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${WORK}/iso/boot/grub/grub.cfg"

# Create EFI directory on ISO
mkdir -p "${WORK}/iso/EFI/boot"
cp "${WORK}/bootx64.efi" "${WORK}/iso/EFI/boot/bootx64.efi"

# Create EFI system partition image
dd if=/dev/zero of="${WORK}/iso/boot/grub/efi.img" bs=1M count=4 2>/dev/null
mkfs.vfat "${WORK}/iso/boot/grub/efi.img"
mmd -i "${WORK}/iso/boot/grub/efi.img" EFI EFI/boot
mcopy -i "${WORK}/iso/boot/grub/efi.img" "${WORK}/bootx64.efi" ::EFI/boot/bootx64.efi

# === Step 6: Build the hybrid ISO ===
echo "==> Building ISO..."
xorriso -as mkisofs \
    -R -J -joliet-long \
    -V "NGSTEP" \
    -b boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    -o "${ISO_NAME}" \
    "${WORK}/iso"

echo "==> Done: ${ISO_NAME}"
ls -lh "${ISO_NAME}"
