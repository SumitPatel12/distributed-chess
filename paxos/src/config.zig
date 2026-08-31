pub const Config = struct {
    node_id: u8,
    cluster_size: u8,
    base_port: u16,
    address: [*:0]const u8,
};
