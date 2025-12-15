const Applet = imports.ui.applet;
const GLib = imports.gi.GLib;
const Gio = imports.gi.Gio;
const Mainloop = imports.mainloop;
const PopupMenu = imports.ui.popupMenu;
const Lang = imports.lang;

function main(metadata, orientation, panelHeight, instanceId) {
    return new PIAVPNApplet(metadata, orientation, panelHeight, instanceId);
}

const PIAVPNApplet = class PIAVPNApplet extends Applet.IconApplet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);
        
        this.metadata = metadata;
        this.orientation = orientation;
        this._menu_manager = null;
        this._menu = null;
        this._inotify_process = null;
        
        this.is_connected = false;
        this.current_port = null;
        this.current_region_name = null;
        this.servers_data = null;
        this._last_toggle_text = null;
        
        this.set_applet_icon_path(this.metadata.path + "/icons/disconnected.png");
        this.set_applet_tooltip("PIA VPN");
    }
    
    on_applet_added_to_panel() {
        if (!this._menu_manager) {
            this._menu_manager = new PopupMenu.PopupMenuManager(this);
            this._menu = new Applet.AppletPopupMenu(this, this.orientation);
            this._menu_manager.addMenu(this._menu);
        }
        
        this._buildMenu();
        this.fetch_servers_data();
        
        // Initial status check
        Mainloop.timeout_add_seconds(1, Lang.bind(this, () => {
            this.update_status();
            return false;
        }));
        
        // Start inotify monitoring for file changes
        this._setupInotifyMonitoring();
    }
    
    on_applet_removed_from_panel() {
        this._stopInotifyMonitoring();
        
        if (this._menu_manager) {
            this._menu_manager.removeMenu(this._menu);
            this._menu = null;
            this._menu_manager = null;
        }
    }
    
    _setupInotifyMonitoring() {
        try {
            // Monitor /var/lib/pia/ for changes to forwarded_port and region.txt
            let proc = new Gio.Subprocess({
                argv: ['inotifywait', '-m', '-e', 'modify,create', '/var/lib/pia/'],
                flags: Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            });
            
            proc.init(null);
            this._inotify_process = proc;
            
            // Read output asynchronously
            let stdout = proc.get_stdout_pipe();
            let stream = new Gio.DataInputStream({ base_stream: stdout });
            
            this._readInotifyLine(stream, proc);
            
        } catch(e) {
            // Fallback: if inotify fails, do nothing - polling is disabled
            // but manual updates on menu open will still work
            this.log("inotify setup failed: " + e);
        }
    }
    
    _readInotifyLine(stream, proc) {
        stream.read_line_async(GLib.PRIORITY_DEFAULT, null, Lang.bind(this, (stream, result) => {
            try {
                let [line, length] = stream.read_line_finish(result);
                
                if (line !== null) {
                    // Any change to /var/lib/pia/ triggers an update
                    Mainloop.idle_add(Lang.bind(this, () => {
                        this.update_status();
                        return false;
                    }));
                    
                    // Continue reading
                    this._readInotifyLine(stream, proc);
                } else {
                    // Stream ended
                    this._inotify_process = null;
                }
            } catch(e) {
                this.log("inotify read error: " + e);
                this._inotify_process = null;
            }
        }));
    }
    
    _stopInotifyMonitoring() {
        if (this._inotify_process) {
            try {
                this._inotify_process.force_exit();
            } catch(e) {
                // Already terminated
            }
            this._inotify_process = null;
        }
    }
    
    on_applet_clicked() {
        if (this._menu) {
            if (!this._menu.isOpen) {
                // Update status when menu opens (in case inotify missed something)
                this.update_status();
            }
            this._menu.toggle();
        }
    }
    
    _buildMenu() {
        this._menu.removeAll();
        
        this.status_item = new PopupMenu.PopupMenuItem("Loading...", { reactive: false });
        this._menu.addMenuItem(this.status_item);
        
        this.port_item = new PopupMenu.PopupMenuItem("Port: -", { reactive: false });
        this._menu.addMenuItem(this.port_item);
        
        this.region_item = new PopupMenu.PopupMenuItem("Region: Unknown", { reactive: false });
        this._menu.addMenuItem(this.region_item);
        
        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        this.toggle_item = new PopupMenu.PopupMenuItem("Disconnect");
        this.toggle_item.connect('activate', Lang.bind(this, this.on_toggle_vpn));
        this._menu.addMenuItem(this.toggle_item);
        
        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        this.servers_menu_item = new PopupMenu.PopupSubMenuMenuItem("Select Server");
        this._menu.addMenuItem(this.servers_menu_item);
        
        if (this.servers_data) {
            this.populate_servers_menu();
        }
        
        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        let refreshItem = new PopupMenu.PopupMenuItem("Find Fastest Server");
        refreshItem.connect('activate', Lang.bind(this, this.on_check_servers));
        this._menu.addMenuItem(refreshItem);
        
        this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        let settingsItem = new PopupMenu.PopupMenuItem("Settings");
        settingsItem.connect('activate', Lang.bind(this, this.on_open_settings));
        this._menu.addMenuItem(settingsItem);
    }
    
    fetch_servers_data() {
        try {
            let [success, output] = GLib.spawn_command_line_sync(
                "curl -s https://serverlist.piaservers.net/vpninfo/servers/v7"
            );
            
            if (success) {
                let json_text = imports.byteArray.toString(output).trim();
                json_text = json_text.split('\n')[0];
                this.servers_data = JSON.parse(json_text);
                this.populate_servers_menu();
            }
        } catch(e) {
            // Silently fail
        }
    }
    
    populate_servers_menu() {
        if (!this.servers_data || !this.servers_data.regions) {
            return;
        }
        
        this.servers_menu_item.menu.removeAll();
        
        let regions = this.servers_data.regions.slice();
        regions.sort((a, b) => a.name.localeCompare(b.name));
        
        for (let i = 0; i < regions.length; i++) {
            let region = regions[i];
            let menu_item = new PopupMenu.PopupMenuItem(region.name);
            
            (Lang.bind(this, function(rid, rname) {
                menu_item.connect('activate', Lang.bind(this, function() {
                    this.on_select_server(rid, rname);
                }));
            }))(region.id, region.name);
            
            this.servers_menu_item.menu.addMenuItem(menu_item);
        }
    }
    
    on_select_server(region_id, region_name) {
        try {
            let pattern1 = "s/^PREFERRED_REGION=.*/PREFERRED_REGION=" + region_id + "/";
            let pattern2 = "s/^AUTOCONNECT=.*/AUTOCONNECT=false/";
            
            let proc1 = Gio.Subprocess.new(
                ['sudo', '-n', 'sed', '-i', pattern1, '/etc/pia-credentials'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            
            proc1.wait_async(null, Lang.bind(this, (proc1, res1) => {
                try {
                    proc1.wait_finish(res1);
                    if (proc1.get_exit_status() === 0) {
                        let proc2 = Gio.Subprocess.new(
                            ['sudo', '-n', 'sed', '-i', pattern2, '/etc/pia-credentials'],
                            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
                        );
                        
                        proc2.wait_async(null, Lang.bind(this, (proc2, res2) => {
                            try {
                                proc2.wait_finish(res2);
                                if (proc2.get_exit_status() === 0) {
                                    Gio.Subprocess.new(
                                        ['sudo', '-n', 'chmod', '644', '/etc/pia-credentials'],
                                        Gio.SubprocessFlags.NONE
                                    );
                                    
                                    Gio.Subprocess.new(['sudo', '-n', 'systemctl', 'restart', 'pia-vpn.service'], 
                                        Gio.SubprocessFlags.NONE);
                                    
                                    Mainloop.timeout_add_seconds(3, Lang.bind(this, () => {
                                        this.update_status();
                                        this._buildMenu();
                                        return false;
                                    }));
                                }
                            } catch(e) {
                                // Error updating
                            }
                        }));
                    }
                } catch(e) {
                    // Error updating
                }
            }));
        } catch(e) {
            // Error selecting server
        }
    }
    
    update_status() {
        this.check_vpn_status();
        this.get_forwarded_port();
        this.get_current_region();
        this.update_ui();
    }
    
    check_vpn_status() {
        try {
            let [success, out] = GLib.spawn_command_line_sync('ip addr show pia');
            this.is_connected = success && out.toString().indexOf("inet ") !== -1;
        } catch(e) {
            this.is_connected = false;
        }
    }
    
    get_forwarded_port() {
        try {
            let file = Gio.file_new_for_path("/var/lib/pia/forwarded_port");
            if (file.query_exists(null)) {
                let [success, contents] = file.load_contents(null);
                if (success) {
                    let text = imports.byteArray.toString(contents).trim();
                    let port = parseInt(text.split(/\s+/)[0]);
                    this.current_port = !isNaN(port) ? port : null;
                    return;
                }
            }
            this.current_port = null;
        } catch(e) {
            this.current_port = null;
        }
    }
    
    get_current_region() {
        try {
            let file = Gio.file_new_for_path("/var/lib/pia/region.txt");
            if (file.query_exists(null)) {
                let [success, contents] = file.load_contents(null);
                if (success) {
                    let text = imports.byteArray.toString(contents);
                    let match = text.match(/hostname=([^\s\n]+)/);
                    
                    if (match && this.servers_data && this.servers_data.regions) {
                        let hostname = match[1];
                        
                        for (let i = 0; i < this.servers_data.regions.length; i++) {
                            let region = this.servers_data.regions[i];
                            for (let protocol in region.servers) {
                                if (region.servers.hasOwnProperty(protocol)) {
                                    let servers = region.servers[protocol];
                                    for (let j = 0; j < servers.length; j++) {
                                        if (servers[j].cn === hostname) {
                                            this.current_region_name = region.name;
                                            return;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            this.current_region_name = null;
        } catch(e) {
            this.current_region_name = null;
        }
    }
    
    update_ui() {
        if (!this.status_item) return;
        
        if (this.is_connected) {
            this.set_applet_icon_path(this.metadata.path + "/icons/connected.png");
            this.status_item.label.set_text("✓ Connected");
        } else {
            this.set_applet_icon_path(this.metadata.path + "/icons/disconnected.png");
            this.status_item.label.set_text("✗ Disconnected");
        }
        
        if (this.toggle_item) {
            let new_text = this.is_connected ? "Disconnect" : "Connect";
            if (new_text !== this._last_toggle_text) {
                this.toggle_item.label.set_text(new_text);
                this._last_toggle_text = new_text;
            }
        }
        
        if (this.port_item) {
            this.port_item.label.set_text(
                (this.is_connected && this.current_port) ? 
                "Port: " + this.current_port : 
                "Port: Not forwarded"
            );
        }
        
        if (this.region_item) {
            this.region_item.label.set_text(
                "Region: " + (this.current_region_name || "Unknown")
            );
        }
        
        let tooltip = "PIA VPN";
        if (this.is_connected) {
            tooltip = this.current_region_name || "Connected";
            if (this.current_port) {
                tooltip += " • Port: " + this.current_port;
            }
        } else {
            tooltip = "Disconnected";
        }
        this.set_applet_tooltip(tooltip);
    }
    
    on_toggle_vpn() {
        try {
            if (this.is_connected) {
                Gio.Subprocess.new(['sudo', 'wg-quick', 'down', 'pia'], Gio.SubprocessFlags.NONE);
            } else {
                Gio.Subprocess.new(['sudo', 'wg-quick', 'up', 'pia'], Gio.SubprocessFlags.NONE);
            }
            
            Mainloop.timeout_add_seconds(2, Lang.bind(this, () => {
                this.update_status();
                return false;
            }));
        } catch(e) {
            // Error toggling VPN
        }
    }
    
    on_check_servers() {
        try {
            let pattern = "s/^AUTOCONNECT=.*/AUTOCONNECT=true/";
            
            let proc = Gio.Subprocess.new(
                ['sudo', '-n', 'sed', '-i', pattern, '/etc/pia-credentials'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            
            proc.wait_async(null, Lang.bind(this, (proc, res) => {
                try {
                    proc.wait_finish(res);
                    if (proc.get_exit_status() === 0) {
                        Gio.Subprocess.new(['sudo', '-n', 'wg-quick', 'down', 'pia'], Gio.SubprocessFlags.NONE);
                        
                        Mainloop.timeout_add_seconds(2, Lang.bind(this, () => {
                            Gio.Subprocess.new(['sudo', '-n', 'systemctl', 'restart', 'pia-vpn.service'], 
                                Gio.SubprocessFlags.NONE);
                            
                            Mainloop.timeout_add_seconds(5, Lang.bind(this, () => {
                                this.update_status();
                                this._buildMenu();
                                return false;
                            }));
                            return false;
                        }));
                    }
                } catch(e) {
                    // Error
                }
            }));
        } catch(e) {
            // Error checking servers
        }
    }
    
    on_open_settings() {
        try {
            Gio.Subprocess.new(['sudo', 'xed', '/etc/pia-credentials'], Gio.SubprocessFlags.NONE);
        } catch(e) {
            // Error opening settings
        }
    }
};
