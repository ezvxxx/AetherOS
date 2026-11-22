const c = @import("c");

const Script = c.hb_script_t;

pub fn script(codepoint: u21) Script {
    return c.hb_unicode_script(c.hb_unicode_funcs_get_default(), codepoint);
}

pub fn generalCategory(codepoint: u21) c.hb_unicode_general_category_t {
    return c.hb_unicode_general_category(c.hb_unicode_funcs_get_default(), codepoint);
}

