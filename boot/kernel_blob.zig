//! The build script embeds the just-built kernel into the standalone EFI loader.
pub const bytes = @embedFile("kernel.elf");
