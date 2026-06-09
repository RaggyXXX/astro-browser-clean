------------------------------------------------------------
-- Chrome UA reference subset for Astro V1.
--
-- Source orientation:
-- Chromium Blink html.css:
-- https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/html/resources/html.css
--
-- This is not a verbatim copy. It is the supported Astro subset expressed
-- in engine property names so verification can catch drift in our UA defaults.
------------------------------------------------------------

return {
    tags = {
        html = {
            display = "block",
            background_color = { 255, 255, 255, 255 },
            color = { 0, 0, 0, 255 },
        },
        body = {
            display = "block",
            margin_top = 8,
            margin_right = 8,
            margin_bottom = 8,
            margin_left = 8,
            background_color = { 255, 255, 255, 255 },
            color = { 0, 0, 0, 255 },
        },
        h1 = { display = "block", font_size = 32, font_weight = 700, margin_top = 21, margin_bottom = 21 },
        h2 = { display = "block", font_size = 24, font_weight = 700, margin_top = 20, margin_bottom = 20 },
        h3 = { display = "block", font_size = 18.72, font_weight = 700, margin_top = 18.72, margin_bottom = 18.72 },
        h4 = { display = "block", font_size = 16, font_weight = 700, margin_top = 21, margin_bottom = 21 },
        h5 = { display = "block", font_size = 13.28, font_weight = 700, margin_top = 22.18, margin_bottom = 22.18 },
        h6 = { display = "block", font_size = 10.72, font_weight = 700, margin_top = 24.98, margin_bottom = 24.98 },
        -- Chrome resolves <p> margin-top/bottom as 1em against the
        -- element's own font-size (not body's). Engine mirrors this with
        -- a structured `{type="em", v=1}` value resolved at layout time.
        -- Numeric 16 was a body-font-size-16 simplification that drifted
        -- by 2px per side on inherited-14 paragraphs.
        p = { display = "block",
              margin_top = { type = "em", v = 1 },
              margin_bottom = { type = "em", v = 1 } },
        div = { display = "block" },
        span = { display = "inline" },
        a = { display = "inline", color = { 0, 0, 238, 255 }, text_decoration = "underline", cursor = "pointer" },
        ul = { display = "block", padding_left = 40, margin_top = 16, margin_bottom = 16, list_style_type = "disc" },
        ol = { display = "block", padding_left = 40, margin_top = 16, margin_bottom = 16, list_style_type = "decimal" },
        menu = { display = "block", padding_left = 40, margin_top = 16, margin_bottom = 16, list_style_type = "disc" },
        li = { display = "list-item" },
        dl = { display = "block", margin_top = 16, margin_bottom = 16 },
        dt = { display = "block" },
        dd = { display = "block", margin_left = 40 },
        blockquote = { display = "block", margin_top = 16, margin_bottom = 16, margin_left = 40, margin_right = 40 },
        address = { display = "block", font_style = "italic" },
        center = { display = "block", text_align = "center" },
        strong = { display = "inline", font_weight = 700 },
        b = { display = "inline", font_weight = 700 },
        em = { display = "inline", font_style = "italic" },
        i = { display = "inline", font_style = "italic" },
        cite = { display = "inline", font_style = "italic" },
        var = { display = "inline", font_style = "italic" },
        abbr = { display = "inline" },
        q = { display = "inline" },
        time = { display = "inline" },
        small = { display = "inline", font_size = 13 },
        mark = { display = "inline", background_color = { 255, 255, 0, 255 }, color = { 0, 0, 0, 255 } },
        pre = { display = "block", white_space = "pre", font_family = "monospace", font_size = 13, margin_top = 13, margin_bottom = 13 },
        code = { display = "inline", font_family = "monospace", font_size = 13 },
        kbd = { display = "inline", font_family = "monospace", font_size = 13 },
        samp = { display = "inline", font_family = "monospace", font_size = 13 },
        sub = { display = "inline", font_size = 11, vertical_align = "sub" },
        sup = { display = "inline", font_size = 11, vertical_align = "super" },
        del = { display = "inline", text_decoration = "line-through" },
        s = { display = "inline", text_decoration = "line-through" },
        strike = { display = "inline", text_decoration = "line-through" },
        ins = { display = "inline", text_decoration = "underline" },
        u = { display = "inline", text_decoration = "underline" },
        br = { display = "block", height = 0 },
        hr = { display = "block", height = 2, margin_top = 8, margin_bottom = 8, border_width = 1 },
        form = { display = "block" },
        label = { display = "inline", cursor = "pointer" },
        option = { display = "none" },
        optgroup = { display = "none", font_weight = 700 },
        fieldset = { display = "block", padding_top = 8, padding_right = 12, padding_bottom = 8, padding_left = 12, border_width = 2, margin_left = 2, margin_right = 2 },
        legend = { display = "block", padding_left = 4, padding_right = 4 },
        table = { display = "table", border_collapse = "separate", border_spacing = 2 },
        thead = { display = "table-header-group" },
        tbody = { display = "table-row-group" },
        tfoot = { display = "table-footer-group" },
        tr = { display = "table-row" },
        td = { display = "table-cell", border_width = 0, vertical_align = "middle" },
        th = { display = "table-cell", border_width = 0, font_weight = 700, text_align = "center", vertical_align = "middle" },
        caption = { display = "table-caption", text_align = "center" },
        img = { display = "inline-block" },
        details = { display = "block" },
        summary = { display = "block", cursor = "pointer" },
    },
}



