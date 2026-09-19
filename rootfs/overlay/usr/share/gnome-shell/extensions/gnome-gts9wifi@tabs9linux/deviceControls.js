// SPDX-License-Identifier: MIT
//
// Talks to /usr/libexec/gts9wifi-device-control, the single place that knows
// which device-specific controls exist and where they live in sysfs.  Keeping
// the table there means this extension never has to change when a control is
// added.
//
// The helper is a short shell script, so these calls are cheap, but they are
// synchronous: they are only made when the settings page is built or a control
// is toggled, never from a timer.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const HELPER_PATH = '/usr/libexec/gts9wifi-device-control';

function callHelper(args) {
    try {
        const proc = Gio.Subprocess.new(
            [HELPER_PATH, ...args],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        const [, stdout] = proc.communicate_utf8(null, null);
        return proc.get_successful() ? stdout : null;
    } catch (error) {
        console.error(`gnome-gts9wifi: ${error.message}`);
        return null;
    }
}

// The extension is shipped by the port, but a user could still install it
// elsewhere, so say plainly that the port is missing rather than throwing.
export function helperAvailable() {
    return GLib.file_test(HELPER_PATH, GLib.FileTest.IS_EXECUTABLE);
}

export function listControls() {
    const output = callHelper(['list']);
    if (output === null)
        return [];

    return output.split('\n')
        .filter(line => line.trim() !== '')
        .map(line => {
            const [name, group, label, description, value] = line.split('\t');
            return {
                name,
                group,
                label,
                description,
                enabled: value === '1',
            };
        });
}

export function setControl(name, enabled) {
    return callHelper(['set', name, enabled ? '1' : '0']) !== null;
}
