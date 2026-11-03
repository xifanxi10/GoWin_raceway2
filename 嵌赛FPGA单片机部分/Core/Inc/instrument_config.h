#ifndef INSTRUMENT_CONFIG_H
#define INSTRUMENT_CONFIG_H
/* 0: pressure + FPGA control only; 1: enable the existing 800x480 display/touch. */
#ifndef INSTRUMENT_DISPLAY_ENABLE
#define INSTRUMENT_DISPLAY_ENABLE 1
#endif

/* Four PCA9555 devices share PB8/PB9. Physical order from the left is based
 * on board testing: 0x21, 0x22, 0x24, 0x20. */
#ifndef PCA9555_I2C_ADDRESS_0_7BIT
#define PCA9555_I2C_ADDRESS_0_7BIT 0x21U
#endif
#ifndef PCA9555_I2C_ADDRESS_1_7BIT
#define PCA9555_I2C_ADDRESS_1_7BIT 0x22U
#endif
#ifndef PCA9555_I2C_ADDRESS_2_7BIT
#define PCA9555_I2C_ADDRESS_2_7BIT 0x24U
#endif
#ifndef PCA9555_I2C_ADDRESS_3_7BIT
#define PCA9555_I2C_ADDRESS_3_7BIT 0x20U
#endif
/* Kept as an alias for older application code; it names the last board. */
#ifndef PCA9555_I2C_ADDRESS_7BIT
#define PCA9555_I2C_ADDRESS_7BIT PCA9555_I2C_ADDRESS_3_7BIT
#endif

/* Set to 1 only when a pressed key pulls its PCA9555 input low. */
#ifndef PCA9555_KEYS_ACTIVE_LOW
#define PCA9555_KEYS_ACTIVE_LOW 0
#endif

#ifndef PCA9555_POLL_PERIOD_MS
#define PCA9555_POLL_PERIOD_MS 2U
#endif

#ifndef PCA9555_RETRY_PERIOD_MS
#define PCA9555_RETRY_PERIOD_MS 100U
#endif
#endif
