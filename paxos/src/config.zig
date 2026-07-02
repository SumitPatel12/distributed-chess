pub const Config = struct {
    node_id: u16,
    cluster_size: u16,
    base_port: u16,
    address: [*:0]const u8,
};
