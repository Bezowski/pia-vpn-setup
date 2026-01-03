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
        this.connection_quality = null;
        this._port_test_in_progress = false;
        
        this.set_applet_icon_path(this.metadata.path + "/icons/disconnected.png");
        this.set_applet_tooltip("PIA VPN");
    }
    
    log(message) {
        global.log(`[PIA VPN Applet] ${message}`);
    }
    
    logError(message, error) {
        global.logError(`[PIA VPN Applet] ${message}: ${error}`);
    }
    
    on_applet_added_to_panel() {
        try {
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
        } catch(e) {
            this.logError("Failed to add applet to panel", e);
        }
    }
    
    on_applet_removed_from_panel() {
        try {
            this._stopInotifyMonitoring();
            
            if (this._menu_manager) {
                this._menu_manager.removeMenu(this._menu);
                this._menu = null;
                this._menu_manager = null;
            }
        } catch(e) {
            this.logError("Failed to remove applet from panel", e);
        }
    }
    
    _setupInotifyMonitoring() {
        try {
            let proc = new Gio.Subprocess({
                argv: ['inotifywait', '-m', '-e', 'modify,create', '/var/lib/pia/'],
                flags: Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            });
            
            proc.init(null);
            this._inotify_process = proc;
            
            let stdout = proc.get_stdout_pipe();
            let stream = new Gio.DataInputStream({ base_stream: stdout });
            
            this._readInotifyLine(stream, proc);
            
        } catch(e) {
            this.logError("inotify setup failed (falling back to manual updates)", e);
        }
    }
    
    _readInotifyLine(stream, proc) {
        stream.read_line_async(GLib.PRIORITY_DEFAULT, null, Lang.bind(this, (stream, result) => {
            try {
                let [line, length] = stream.read_line_finish(result);
                
                if (line !== null) {
                    Mainloop.idle_add(Lang.bind(this, () => {
                        this.update_status();
                        return false;
                    }));
                    
                    this._readInotifyLine(stream, proc);
                } else {
                    this.log("inotify stream ended");
                    this._inotify_process = null;
                }
            } catch(e) {
                this.logError("inotify read error", e);
                this._inotify_process = null;
            }
        }));
    }
    
    _stopInotifyMonitoring() {
        if (this._inotify_process) {
            try {
                this._inotify_process.force_exit();
            } catch(e) {
                this.logError("Failed to stop inotify process", e);
            }
            this._inotify_process = null;
        }
    }
    
    on_applet_clicked() {
        try {
            if (this._menu) {
                if (!this._menu.isOpen) {
                    this.update_status();
                }
                this._menu.toggle();
            }
        } catch(e) {
            this.logError("Failed to toggle menu", e);
        }
    }
    
    _buildMenu() {
        try {
            this._menu.removeAll();
            
            // Status section
            this.status_item = new PopupMenu.PopupMenuItem("Loading...", { reactive: false });
            this._menu.addMenuItem(this.status_item);
            
            this.quality_item = new PopupMenu.PopupMenuItem("Quality: Checking...", { reactive: false });
            this._menu.addMenuItem(this.quality_item);
            
            this.port_item = new PopupMenu.PopupMenuItem("Port: -", { reactive: false });
            this._menu.addMenuItem(this.port_item);
            
            this.region_item = new PopupMenu.PopupMenuItem("Region: Unknown", { reactive: false });
            this._menu.addMenuItem(this.region_item);
            
            this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            
            // Quick actions section
            this.disconnect_item = new PopupMenu.PopupMenuItem("Disconnect");
            this.disconnect_item.connect('activate', Lang.bind(this, this.on_quick_disconnect));
            this._menu.addMenuItem(this.disconnect_item);
            
            this.reconnect_item = new PopupMenu.PopupMenuItem("Reconnect");
            this.reconnect_item.connect('activate', Lang.bind(this, this.on_quick_reconnect));
            this._menu.addMenuItem(this.reconnect_item);
            
            this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            
            // Port test button (always show, will be disabled if no port)
            this.port_test_item = new PopupMenu.PopupMenuItem("Test Port", { reactive: false });
            this._menu.addMenuItem(this.port_test_item);
            
            // Add clickable area that doesn't close menu
            this.port_test_item.actor.connect('button-press-event', Lang.bind(this, function() {
                this.on_test_port();
                return true; // Prevent menu from closing
            }));
            
            this._menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            
            // Server selection
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
        } catch(e) {
            this.logError("Failed to build menu", e);
        }
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
            } else {
                this.logError("Failed to fetch servers data", "Command returned failure");
            }
        } catch(e) {
            this.logError("Failed to fetch or parse servers data", e);
        }
    }
    
    populate_servers_menu() {
        try {
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
        } catch(e) {
            this.logError("Failed to populate servers menu", e);
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
                                this.logError("Failed to update AUTOCONNECT setting", e);
                            }
                        }));
                    }
                } catch(e) {
                    this.logError("Failed to update PREFERRED_REGION setting", e);
                }
            }));
        } catch(e) {
            this.logError("Failed to select server", e);
        }
    }
    
    update_status() {
        try {
            this.check_vpn_status();
            this.get_forwarded_port();
            this.get_current_region();
            this.check_connection_quality();
            this.update_ui();
        } catch(e) {
            this.logError("Failed to update status", e);
        }
    }
    
    check_vpn_status() {
        try {
            let [success, out] = GLib.spawn_command_line_sync('ip addr show pia');
            this.is_connected = success && out.toString().indexOf("inet ") !== -1;
        } catch(e) {
            this.logError("Failed to check VPN status", e);
            this.is_connected = false;
        }
    }
    
    check_connection_quality() {
        if (!this.is_connected) {
            this.connection_quality = null;
            return;
        }
        
        try {
            // Quick ping test to PIA DNS server
            let [success, output] = GLib.spawn_command_line_sync(
                'ping -c 1 -W 2 10.0.0.243'
            );
            
            if (success) {
                let output_str = imports.byteArray.toString(output);
                let match = output_str.match(/time=([0-9.]+)\s*ms/);
                
                if (match) {
                    let latency = parseFloat(match[1]);
                    
                    if (latency < 50) {
                        this.connection_quality = "Excellent (" + Math.round(latency) + "ms)";
                    } else if (latency < 100) {
                        this.connection_quality = "Good (" + Math.round(latency) + "ms)";
                    } else if (latency < 200) {
                        this.connection_quality = "Fair (" + Math.round(latency) + "ms)";
                    } else {
                        this.connection_quality = "Poor (" + Math.round(latency) + "ms)";
                    }
                } else {
                    this.connection_quality = "Unknown";
                }
            } else {
                this.connection_quality = "No response";
            }
        } catch(e) {
            this.logError("Failed to check connection quality", e);
            this.connection_quality = "Error";
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
            this.logError("Failed to get forwarded port", e);
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
                    
                    if (match) {
                        let hostname = match[1].trim();
                        this.log("Found hostname: " + hostname);
                        
                        if (!this.servers_data || !this.servers_data.regions) {
                            this.log("No servers data available");
                            this.current_region_name = hostname; // Fallback to hostname
                            return;
                        }
                        
                        // Extract base name (e.g., "sydney428" -> "sydney", "melbourne433" -> "melbourne")
                        let basename = hostname.replace(/[0-9]+$/, '').toLowerCase();
                        this.log("Extracted basename: " + basename);
                        
                        // Try exact match first
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
                        
                        // Try matching by region ID or name containing basename
                        for (let i = 0; i < this.servers_data.regions.length; i++) {
                            let region = this.servers_data.regions[i];
                            let region_name_lower = region.name.toLowerCase();
                            let region_id_lower = region.id.toLowerCase();
                            
                            // Check if region name or ID contains the basename
                            if (region_name_lower.includes(basename) || 
                                basename.includes(region_id_lower) || 
                                region_id_lower.includes(basename)) {
                                this.current_region_name = region.name;
                                return;
                            }
                        }
                        
                        // Last resort: use the hostname itself
                        this.log("No region match found, using hostname");
                        this.current_region_name = hostname;
                        return;
                    }
                }
            }
            this.current_region_name = null;
        } catch(e) {
            this.logError("Failed to get current region", e);
            this.current_region_name = null;
        }
    }
    
    update_ui() {
        try {
            if (!this.status_item) return;
            
            if (this.is_connected) {
                this.set_applet_icon_path(this.metadata.path + "/icons/connected.png");
                this.status_item.label.set_text("✓ Connected");
            } else {
                this.set_applet_icon_path(this.metadata.path + "/icons/disconnected.png");
                this.status_item.label.set_text("✗ Disconnected");
            }
            
            // Update connection quality
            if (this.quality_item) {
                if (this.is_connected && this.connection_quality) {
                    this.quality_item.label.set_text("Quality: " + this.connection_quality);
                } else if (this.is_connected) {
                    this.quality_item.label.set_text("Quality: Checking...");
                } else {
                    this.quality_item.label.set_text("Quality: N/A");
                }
            }
            
            if (this.port_item) {
                this.port_item.label.set_text(
                    (this.is_connected && this.current_port) ? 
                    "Port: " + this.current_port : 
                    "Port: Not forwarded"
                );
            }
            
            // Update port test button state
            if (this.port_test_item) {
                if (this._port_test_in_progress) {
                    this.port_test_item.actor.reactive = false;
                    this.port_test_item.actor.can_focus = false;
                    // Keep current text during test
                } else if (this.current_port) {
                    this.port_test_item.actor.reactive = true;
                    this.port_test_item.actor.can_focus = true;
                    // Use shorter text to prevent truncation
                    this.port_test_item.label.set_text("Test Port");
                } else {
                    this.port_test_item.actor.reactive = false;
                    this.port_test_item.actor.can_focus = false;
                    this.port_test_item.label.set_text("Test Port");
                }
            }
            
            if (this.region_item) {
                this.region_item.label.set_text(
                    "Region: " + (this.current_region_name || "Unknown")
                );
            }
            
            let tooltip = "PIA VPN";
            if (this.is_connected) {
                tooltip = this.current_region_name || "Connected";
                if (this.connection_quality) {
                    tooltip += " • " + this.connection_quality;
                }
                if (this.current_port) {
                    tooltip += " • Port: " + this.current_port;
                }
            } else {
                tooltip = "Disconnected";
            }
            this.set_applet_tooltip(tooltip);
        } catch(e) {
            this.logError("Failed to update UI", e);
        }
    }
    
    on_quick_disconnect() {
        try {
            // Pause watchdog before disconnecting
            Gio.Subprocess.new(['sudo', '-n', '/usr/local/bin/pia-watchdog.sh', 'pause'], 
                Gio.SubprocessFlags.NONE);
            
            // Stop port forwarding first
            Gio.Subprocess.new(['sudo', '-n', 'systemctl', 'stop', 'pia-port-forward.service'], 
                Gio.SubprocessFlags.NONE);
            
            // Then disconnect VPN
            Gio.Subprocess.new(['sudo', '-n', 'wg-quick', 'down', 'pia'], 
                Gio.SubprocessFlags.NONE);
            
            Mainloop.timeout_add_seconds(2, Lang.bind(this, () => {
                this.update_status();
                return false;
            }));
        } catch(e) {
            this.logError("Failed to disconnect VPN", e);
        }
    }

    on_quick_reconnect() {
        try {
            // Use systemctl restart to get fresh token and config
            Gio.Subprocess.new(['sudo', '-n', 'systemctl', 'restart', 'pia-vpn.service'], 
                Gio.SubprocessFlags.NONE);
            
            // Resume watchdog after reconnecting
            Mainloop.timeout_add_seconds(6, Lang.bind(this, () => {
                Gio.Subprocess.new(['sudo', '-n', '/usr/local/bin/pia-watchdog.sh', 'resume'], 
                    Gio.SubprocessFlags.NONE);
                
                this.update_status();
                return false;
            }));
        } catch(e) {
            this.logError("Failed to reconnect VPN", e);
        }
    }
    
    on_test_port() {
        if (this._port_test_in_progress) {
            return;
        }
        
        if (!this.current_port) {
            return;
        }
        
        try {
            this._port_test_in_progress = true;
            let port = this.current_port;
            
            if (this.port_test_item) {
                this.port_test_item.label.set_text("Testing...");
            }
            
            let url = "https://www.slsknet.org/porttest.php?port=" + port;
            
            let proc = Gio.Subprocess.new(
                ['curl', '-s', '--max-time', '10', url],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            
            proc.communicate_utf8_async(null, null, Lang.bind(this, (proc, result) => {
                try {
                    let [, stdout, stderr] = proc.communicate_utf8_finish(result);
                    
                    if (stdout && stdout.indexOf('open') !== -1) {
                        if (this.port_test_item) {
                            this.port_test_item.label.set_text("✓ Port OPEN");
                        }
                    } else if (stdout && stdout.indexOf('CLOSED') !== -1) {
                        if (this.port_test_item) {
                            this.port_test_item.label.set_text("✗ Port CLOSED");
                        }
                    } else {
                        if (this.port_test_item) {
                            this.port_test_item.label.set_text("⚠ Test failed");
                        }
                    }
                    
                    // Reset button after 3 seconds
                    Mainloop.timeout_add_seconds(3, Lang.bind(this, () => {
                        this._port_test_in_progress = false;
                        this.update_ui(); // This will reset to "Test Port"
                        return false;
                    }));
                    
                } catch(e) {
                    this.logError("Port test failed", e);
                    if (this.port_test_item) {
                        this.port_test_item.label.set_text("✗ Test failed");
                    }
                    this._port_test_in_progress = false;
                }
            }));
            
        } catch(e) {
            this.logError("Failed to initiate port test", e);
            this._port_test_in_progress = false;
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
                    this.logError("Failed to enable autoconnect", e);
                }
            }));
        } catch(e) {
            this.logError("Failed to check servers", e);
        }
    }
    
    on_open_settings() {
        try {
            Gio.Subprocess.new(['sudo', 'xed', '/etc/pia-credentials'], Gio.SubprocessFlags.NONE);
        } catch(e) {
            this.logError("Failed to open settings", e);
        }
    }
};
