// SPDX-License-Identifier: MIT
//
// All of this extension's UI is its settings page (prefs.js), which is where
// the device-specific controls live.  There is deliberately no panel or Quick
// Settings presence: these are set-once controls rather than something worth
// toggling from the top bar, and on a tablet a stray panel toggle is easy to
// hit by accident.
//
// The extension still has to be enabled for its settings page to be reachable
// from the Extensions app, so this class exists and does nothing else.

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class Gts9wifiExtension extends Extension {
    enable() {
    }

    disable() {
    }
}
