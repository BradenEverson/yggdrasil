#include "driver/i2c_master.h"

esp_err_t shim_i2c_new_bus(int sda, int scl, i2c_master_bus_handle_t *out)
{
    i2c_master_bus_config_t cfg = {
        .i2c_port = -1,
        .sda_io_num = sda,
        .scl_io_num = scl,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .intr_priority = 0,
        .trans_queue_depth = 0,
        .flags.enable_internal_pullup = 1,
    };
    return i2c_new_master_bus(&cfg, out);
}

esp_err_t shim_i2c_add_device(i2c_master_bus_handle_t bus, uint16_t addr,
                              uint32_t speed_hz, i2c_master_dev_handle_t *out)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = addr,
        .scl_speed_hz = speed_hz,
    };
    return i2c_master_bus_add_device(bus, &cfg, out);
}
