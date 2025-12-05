#![no_std]

#[no_mangle]
pub extern "C" fn transform_input(x: i32) -> i32 {
    x * 2
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
