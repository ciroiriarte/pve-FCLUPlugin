// Hitachi Block storage plugin — Proxmox VE web UI integration.
//
// Loaded by the browser *after* pvemanagerlib.js. The Debian package injects a
// <script> tag into /usr/share/pve-manager/index.html.tpl via a dpkg trigger
// (re-applied automatically whenever pve-manager rewrites the template);
// `make install` does the same for source installs.
//
// PVE has no supported external-JS hook for storage backends, so this mirrors
// the in-tree manager6 contract (PVE.panel.StorageBase / PVE.Utils.storageSchema).
// Registering the `hitachiblock` type makes the array storage:
//   * render a friendly "Hitachi Block" label in the Datacenter -> Storage grid
//     (instead of the raw `hitachiblock` type token), and
//   * appear in the "Add" storage drop-down with a create/edit dialog.
//
// Keep the fields below in sync with properties()/options() in
// PVE/Storage/Custom/HitachiBlockPlugin.pm.

Ext.define('PVE.storage.HitachiBlockInputPanel', {
    extend: 'PVE.panel.StorageBase',

    onlineHelp: 'storage_hitachiblock',

    initComponent: function() {
        let me = this;

        // `mgmt_ip`, `storage_id`, `pool_id`, `target_ports` are `fixed` in the
        // plugin's options() — immutable after create, so show them read-only on
        // edit. StorageBase prepends the storage ID field to column1.
        me.column1 = [
            {
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'mgmt_ip',
                fieldLabel: gettext('Management endpoint'),
                emptyText: 'CTL1,CTL2',
                allowBlank: false,
            },
            {
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'storage_id',
                fieldLabel: gettext('Storage device ID'),
                allowBlank: false,
            },
            {
                xtype: me.isCreate ? 'proxmoxintegerfield' : 'displayfield',
                name: 'pool_id',
                fieldLabel: gettext('DP pool ID'),
                minValue: 0,
                allowBlank: false,
            },
            {
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'target_ports',
                fieldLabel: gettext('Target FC ports'),
                emptyText: 'CL1-A,CL2-A',
                allowBlank: false,
            },
        ];

        // StorageBase prepends Nodes + Enable to column2.
        me.column2 = [
            {
                xtype: 'textfield',
                name: 'username',
                fieldLabel: gettext('Username'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                inputType: 'password',
                name: 'password',
                fieldLabel: gettext('Password'),
                // On edit the password lives in the cluster cred store, not in
                // storage.cfg; leave blank to keep the stored value.
                allowBlank: !me.isCreate,
                emptyText: me.isCreate ? '' : gettext('Unchanged'),
            },
            {
                xtype: 'pveContentTypeSelector',
                cts: ['images', 'rootdir'],
                name: 'content',
                fieldLabel: gettext('Content'),
                value: ['images'],
                multiSelect: true,
                allowBlank: false,
            },
        ];

        // Shared must be 1 for clustered (FC SAN) operation — default on.
        me.columnB = [
            {
                xtype: 'proxmoxcheckbox',
                name: 'shared',
                fieldLabel: gettext('Shared'),
                checked: true,
                uncheckedValue: 0,
            },
        ];

        // ── Advanced ────────────────────────────────────────────────────────
        me.advancedColumn1 = [
            {
                xtype: 'proxmoxKVComboBox',
                name: 'platform',
                fieldLabel: gettext('Platform'),
                value: 'vsp_one',
                deleteEmpty: !me.isCreate,
                comboItems: [
                    ['vsp_one', 'VSP One Block (REST :443)'],
                    ['vsp_e', 'VSP E series (REST :443)'],
                    ['vsp_g', 'VSP G series (Ops Center CM :23451)'],
                ],
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'mgmt_port',
                fieldLabel: gettext('Management port'),
                minValue: 1,
                maxValue: 65535,
                emptyText: gettext('auto (from platform)'),
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'snap_pool_id',
                fieldLabel: gettext('Snapshot pool ID'),
                minValue: 0,
                emptyText: gettext('= DP pool'),
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxtextfield',
                name: 'host_mode',
                fieldLabel: gettext('Host mode'),
                emptyText: 'LINUX/IRIX',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxtextfield',
                name: 'host_mode_options',
                fieldLabel: gettext('Host mode options'),
                emptyText: '68',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxtextfield',
                name: 'ldev_range',
                fieldLabel: gettext('LDEV range'),
                emptyText: '1000-1999',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'copy_speed',
                fieldLabel: gettext('Clone copy speed'),
                minValue: 1,
                maxValue: 15,
                emptyText: '3',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
        ];

        me.advancedColumn2 = [
            {
                xtype: 'proxmoxintegerfield',
                name: 'qos_upper_iops',
                fieldLabel: gettext('QoS upper IOPS'),
                minValue: 0,
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'qos_upper_mbps',
                fieldLabel: gettext('QoS upper MB/s'),
                minValue: 0,
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'qos_lower_iops',
                fieldLabel: gettext('QoS lower IOPS'),
                minValue: 0,
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'qos_lower_mbps',
                fieldLabel: gettext('QoS lower MB/s'),
                minValue: 0,
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'qos_priority',
                fieldLabel: gettext('QoS priority (1-3)'),
                minValue: 1,
                maxValue: 3,
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'port_scheduler',
                fieldLabel: gettext('Spread LUNs across ports'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'discard_zero_page',
                fieldLabel: gettext('Reclaim zero pages'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'group_delete',
                fieldLabel: gettext('Delete empty host groups'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'skip_unmap_io_check',
                fieldLabel: gettext('Skip unmap I/O check'),
                // HMO 91: add the Hitachi host-mode option that lets LUN-path
                // teardown skip the array's "executing host I/O" interlock, so
                // free runs immediately instead of retrying with backoff. Safe
                // because the plugin always tears the host side down first.
                boxLabel: gettext('Add HMO 91 (faster teardown)'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'persistent_reservations',
                fieldLabel: gettext('SCSI-3 PR readiness'),
                // Opt-in: when set, activate_volume validates this node's host-side
                // PR plumbing (qemu-pr-helper + multipath reservation_key) for the
                // LUN and warns if not ready. Validate-and-warn only; never edits
                // multipath.conf. For shared/clustered guest disks. Off by default.
                boxLabel: gettext('Validate host SCSI-3 PR plumbing (clustered disks)'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'rest_keepalive',
                fieldLabel: gettext('Keep REST session'),
                // Off (session-less) is the default; only enable for arrays that
                // require session auth, mindful of the per-array session cap.
                boxLabel: gettext('Persistent CM session per process'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'lock_timeout',
                fieldLabel: gettext('Lock acquire timeout (s)'),
                minValue: 10,
                emptyText: '120',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'debug',
                fieldLabel: gettext('Debug log level'),
                // 0=off, 1=basic ops, 2=+REST timing, 3=trace (bodies, redacted).
                // Written to syslog/journal (tag HitachiBlock); never logs secrets.
                minValue: 0,
                maxValue: 3,
                emptyText: '0',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'tls_verify',
                fieldLabel: gettext('Verify TLS certificate'),
                uncheckedValue: 0,
                deleteDefaultValue: !me.isCreate,
            },
            {
                xtype: 'proxmoxtextfield',
                name: 'tls_ca_file',
                fieldLabel: gettext('TLS CA bundle'),
                emptyText: '/etc/pve/...',
                allowBlank: true,
                deleteEmpty: !me.isCreate,
            },
        ];

        me.callParent();
    },

    onGetValues: function(values) {
        let me = this;
        // Never overwrite the stored credential with an empty password field.
        if (!values.password) {
            delete values.password;
        }
        return me.callParent([values]);
    },
});

// Register the type with the manager6 UI: friendly grid label + "Add" entry.
// Guarded so a load-order surprise degrades gracefully instead of throwing.
if (typeof PVE !== 'undefined' && PVE.Utils && PVE.Utils.storageSchema) {
    PVE.Utils.storageSchema.hitachiblock = {
        name: 'Hitachi Block',
        ipanel: 'HitachiBlockInputPanel',
        faIcon: 'database',
        backups: false,
    };
}
