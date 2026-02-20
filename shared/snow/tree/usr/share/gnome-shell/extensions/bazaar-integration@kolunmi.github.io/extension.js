/* extension.js
 *
 * Copyright (C) 2025 Alexander Vanhee
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as AppMenu from 'resource:///org/gnome/shell/ui/appMenu.js';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export default class BazaarIntegration extends Extension {
    enable() {
        this._originalUpdateDetailsVisibility = AppMenu.AppMenu.prototype._updateDetailsVisibility;
        this._originalSetApp = AppMenu.AppMenu.prototype.setApp;
        this._originalAddAction = AppMenu.AppMenu.prototype.addAction;
        const extension = this;
        
        AppMenu.AppMenu.prototype._updateDetailsVisibility = function() {
            const hasBazaar = this._appSystem.lookup_app('io.github.kolunmi.Bazaar.desktop') !== null;
            const isFlatpak = this._app ? extension._isFlatpakApp(this._app) : false;

            this._detailsItem.visible = hasBazaar && isFlatpak;
        };
        
        AppMenu.AppMenu.prototype.setApp = function(app) {
            extension._originalSetApp.call(this, app);
            this._updateDetailsVisibility();
        };
        
        AppMenu.AppMenu.prototype.addAction = function(label, callback) {
            const item = extension._originalAddAction.call(this, label, callback);
            
            if (label === 'App Details' || label === _('App Details')) {
                item.disconnect(item._activateId);
                item._activateId = item.connect('activate', async () => {
                    extension._openInBazaar(this._app);
                });
            }
            
            return item;
        };
    }

    disable() {
        if (this._originalUpdateDetailsVisibility) {
            AppMenu.AppMenu.prototype._updateDetailsVisibility = this._originalUpdateDetailsVisibility;
            this._originalUpdateDetailsVisibility = null;
        }
        
        if (this._originalSetApp) {
            AppMenu.AppMenu.prototype.setApp = this._originalSetApp;
            this._originalSetApp = null;
        }
        
        if (this._originalAddAction) {
            AppMenu.AppMenu.prototype.addAction = this._originalAddAction;
            this._originalAddAction = null;
        }
    }

    _isFlatpakApp(app) {
        if (!app) return false;
        
        const appInfo = app.get_app_info();
        if (!appInfo) return false;
        
        const filename = appInfo.get_filename();
        if (!filename) return false;
        
        // Check if the Desktop file is in a Flatpak directory
        const isFlatpak = filename.includes('/flatpak/exports/share/applications/') ||
                         filename.includes('/var/lib/flatpak/') ||
                         filename.startsWith(GLib.get_home_dir() + '/.local/share/flatpak/');
        
        console.log(`Bazaar Integration: Is Flatpak (by path): ${isFlatpak}`);
        
        return isFlatpak;
    }

    async _openInBazaar(app) {
        if (!app) return;
        
        const appId = app.get_id();
        if (!appId) return;
        
        const cleanAppId = appId.replace(/\.desktop$/, '');
        const appstreamUri = `appstream:${cleanAppId}`;

        GLib.spawn_command_line_async(`flatpak run io.github.kolunmi.Bazaar ${appstreamUri}`);
        Main.overview.hide();
    }
}

