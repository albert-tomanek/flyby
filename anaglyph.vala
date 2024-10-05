public enum AnaglyphMethod
{
    NONE = 0,
    TRUE = 1,
    GRAY = 2,
    HALFCOLOR = 3,
    COLOR = 4
}

public Gdk.Pixbuf make_anaglyph(
    Gdk.Pixbuf left,
    Gdk.Pixbuf right,
    AnaglyphMethod method,
    float red_coef = 1.0f   // In some 3D glasses the red filter may block more light than the blue one, so the red channel can be multiplied by this coefficient (>1.0) to compensate for the lower luminousity.
)
requires (left.width           == right.width)
requires (left.height          == right.height)
requires (left.bits_per_sample == right.bits_per_sample && right.bits_per_sample == 8)
requires (left.colorspace      == right.colorspace      && right.colorspace      == Gdk.Colorspace.RGB)
requires (left.has_alpha       == right.has_alpha       && right.has_alpha       == false)
requires (left.n_channels      == right.n_channels      && right.n_channels      == 3)
{
    if (method == AnaglyphMethod.NONE)
        return left;

    unowned uint8[] data_left  = left.get_pixels_with_length();
    unowned uint8[] data_right = right.get_pixels_with_length();
            uint8[] data_out   = new uint8[data_left.length];

    dotprod_rgb8(
        data_left,
        data_right,
        _chan_vectors[method*18:method*18+9],
        _chan_vectors[method*18+9:method*18+18],
        ref data_out,
        red_coef
    );

    return new Gdk.Pixbuf.from_data(data_out, Gdk.Colorspace.RGB, false, 8, left.width, left.height, left.rowstride);
}

const float[] _chan_vectors = {
    // Taken from here: https://3dtv.at//Knowhow/AnaglyphComparison_en.aspx
    // Transposed for some reason?

    /* TRUE */    
    // left matrix
    0.299f, 0, 0,
    0.587f, 0, 0,
    0.114f, 0, 0,

    // right matrix
    0, 0, 0.299f,
    0, 0, 0.587f,
    0, 0, 0.117f,

    /* GRAY */
    0.299f, 0, 0,
    0.587f, 0, 0,
    0.114f, 0, 0,

    0, 0.299f, 0.299f,
    0, 0.587f, 0.587f,
    0, 0.114f, 0.117f,

    /* HALFCOLOR */
    0.299f, 0, 0,
    0.587f, 0, 0,
    0.114f, 0, 0,

    0, 0, 0,
    0, 1, 0,
    0, 0, 1,

    /* COLOR */
    1, 0, 0,
    0, 0, 0,
    0, 0, 0,

    0, 0, 0,
    0, 1, 0,
    0, 0, 1,
};

private void dotprod_rgb8(uint8[] d_l, uint8[] d_r, float[] mat_l, float[] mat_r, ref uint8[] d_out, float _red_coef = 1)
requires(d_l.length == d_r.length)
requires(d_l.length == d_out.length)
requires(d_l.length % 3 == 0)
requires(mat_l.length >= 9 && mat_r.length >= 9)
{
    for (size_t i = 0; i < d_l.length; i += 3)
    {
        float l_r = ((float) d_l[i])   / 255;
        float l_g = ((float) d_l[i+1]) / 255;
        float l_b = ((float) d_l[i+2]) / 255;

        float r_r = ((float) d_r[i])   / 255;
        float r_g = ((float) d_r[i+1]) / 255;
        float r_b = ((float) d_r[i+2]) / 255;

        float o_r = ((l_r * mat_l[0] + l_g * mat_l[3] + l_b * mat_l[6]) + (r_r * mat_r[0] + r_g * mat_r[3] + r_b * mat_r[6])) / 2;
        float o_g = ((l_r * mat_l[1] + l_g * mat_l[4] + l_b * mat_l[7]) + (r_r * mat_r[1] + r_g * mat_r[4] + r_b * mat_r[7])) / 2;
        float o_b = ((l_r * mat_l[2] + l_g * mat_l[5] + l_b * mat_l[8]) + (r_r * mat_r[2] + r_g * mat_r[5] + r_b * mat_r[8])) / 2;
        
        o_r = float.min(1, o_r * _red_coef);
        d_out[i]   = (uint8) (o_r * 255);
        d_out[i+1] = (uint8) (o_g * 255);
        d_out[i+2] = (uint8) (o_b * 255);
    }
}
