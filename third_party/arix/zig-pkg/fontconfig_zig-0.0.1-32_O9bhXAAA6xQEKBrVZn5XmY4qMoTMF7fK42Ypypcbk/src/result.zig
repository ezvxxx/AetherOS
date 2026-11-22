const c = @import("c");

pub const Error = error{
    OutOfMemory,
    TypeMismatch,
    UnexpectedResult,
};

pub fn found(value: c.FcResult) Error!bool {
    return switch (value) {
        c.FcResultMatch => true,
        c.FcResultNoMatch, c.FcResultNoId => false,
        c.FcResultTypeMismatch => error.TypeMismatch,
        c.FcResultOutOfMemory => error.OutOfMemory,
        else => error.UnexpectedResult,
    };
}
