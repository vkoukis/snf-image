
get_img_dev() {
	echo /dev/vda
}

launch_helper() {
	local jail result_file result snapshot rc floppy blockdev

    blockdev="$1"
    floppy="$2"

    # Invoke the helper vm to do the dirty job...
    jail=$(mktemp -d --tmpdir tmpfsXXXXXXX)
    add_cleanup rmdir "$jail"

    mount tmpfs -t tmpfs "$jail" -o size=1G
    add_cleanup umount -l "$jail"

    result_file=$(mktemp --tmpdir="$jail" result.XXXXXX)
    add_cleanup rm "$result_file"

    snapshot=$(mktemp --tmpdir="$jail" helperXXXXXX.img)
    add_cleanup rm "$snapshot"

    "$QEMU_IMG" create -f qcow2 -b "$HELPER_DIR/image" "$snapshot"

    report_info "Starting customization VM..."
    echo "$($DATE +%Y:%m:%d-%H:%M:%S.%N) VM START" >&2

    set +e

    $TIMEOUT -k "$HELPER_HARD_TIMEOUT" "$HELPER_SOFT_TIMEOUT" \
      kvm -runas "$HELPER_USER" -drive file="$snapshot" \
      -drive file="$blockdev",format=raw,if=virtio,cache=none \
      -boot c -serial stdio -serial "file:$(printf "%q" "$result_file")" \
      -serial file:>(./helper-monitor.py ${MONITOR_FD}) \
      -fda "$floppy" -vga none -nographic -parallel none -monitor null \
      -kernel "$HELPER_DIR/kernel" -initrd "$HELPER_DIR/initrd" \
      -append "quiet ro root=/dev/sda1 console=ttyS0,9600n8 \
             hypervisor=$HYPERVISOR snf_image_activate_helper \
			 rules_dev=/dev/fd0 init=/usr/bin/snf-image-helper" \
      2>&1 | sed -u 's|^|HELPER: |g'

    rc=$?
    set -e
    echo "$($DATE +%Y:%m:%d-%H:%M:%S.%N) VM STOP" >&2
    if [ $rc -ne 0 ]; then
        if [ $rc -eq 124 ];  then
            log_error "Customization VM was terminated. Did not finish on time."
            report_error "Image customization failed. Did not finish on time."
        elif [ $rc -eq 137 ]; then # (128 + SIGKILL)
            log_error "Customization VM was killed. Did not finish on time."
            report_error "Image customization failed. Did not finish on time."
        elif [ $rc -eq 141 ]; then # (128 + SIGPIPE)
            log_error "Customization VM was terminated by a SIGPIPE."
            log_error "Maybe progress monitor has died unexpectedly."
        elif [ $rc -eq 125 ]; then
            log_error "Internal Error. Image customization could not start."
            log_error "timeout did not manage to run."
        else
            log_error "Customization VM died unexpectedly (return code $rc)."
        fi
        exit 1
    else
        report_info "Customization VM exited normally."
    fi

    report_info "Checking customization status..."
    # Read the first line. This will remove \r and \n chars
    result=$(sed 's|\r||g' "$result_file" | head -1)
    report_info "Customization status is: $result"

    if [ "x$result" != "xSUCCESS" ]; then
        log_error "Image customization failed."
        report_error "Image customization failed."
        exit 1
    fi
}

# vim: set sta sts=4 shiftwidth=4 sw=4 et ai :