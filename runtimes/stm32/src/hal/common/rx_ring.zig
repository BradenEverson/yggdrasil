const RX_RING_SIZE: u32 = 512;

pub const RxRing = struct {
    buf: [RX_RING_SIZE]u8 = undefined,
    head: u32 = 0,
    tail: u32 = 0,
    enabled: bool = false,
    dropped: u32 = 0,

    pub fn push(ring: *RxRing, byte: u8) void {
        const head = @atomicLoad(u32, &ring.head, .monotonic);
        const tail = @atomicLoad(u32, &ring.tail, .acquire);
        if (head -% tail >= RX_RING_SIZE) {
            ring.dropped +%= 1;
            return;
        }
        ring.buf[head % RX_RING_SIZE] = byte;
        @atomicStore(u32, &ring.head, head +% 1, .release);
    }

    pub fn pop(ring: *RxRing) ?u8 {
        const tail = @atomicLoad(u32, &ring.tail, .monotonic);
        const head = @atomicLoad(u32, &ring.head, .acquire);
        if (head == tail) return null;
        const byte = ring.buf[tail % RX_RING_SIZE];
        @atomicStore(u32, &ring.tail, tail +% 1, .release);
        return byte;
    }
};
