defmodule Contex.Bridge do
  @moduledoc """
  Draws a bridge from a `Contex.Dataset`.

  `Contex.Bridge` will attempt to create reasonable output with minimal input. The defaults are as follows:
  - Bars will be drawn vertically (use `orientation/2` to override - options are `:horizontal` and `:vertical`)
  - The first column of the dataset is used as the category column (i.e. the bar), and the second
  column is used as the value column (i.e. the bar height). These can be overridden
  with `set_cat_col_name/2` and `set_val_col_names/2`
  - The bridge type defaults to `:stacked`. This doesn't really matter when you only have one series (one value column)
  but if you accept the defaults and then add another value column you will see stacked bars rather than grouped. You
  can override this with `type/2`
  - By default the chart will be annotated with data labels (i.e. the value of a bar will be printed on a bar). This
  can be overridden with `data_labels/2`. This override has no effect when there are 4 or more value columns specified.
  - By default, the padding between the data series is 2 (how this translates into pixels depends on the plot size you specify
  when adding the bridge to a `Contex.Plot`)

  By default the Bridge figures out reasonable value axes. In the case of a `:stacked` bar chart it find the maximum
  of the sum of the values for each category and the value axis is set to {0, that_max}. For a `:grouped` bar chart the
  value axis minimum is set to the minimum value for any category and series, and likewise, the maximum is set to the
  maximum value for any category and series. This may not work. For example, in the situation where you want zero to be
  shown. You can force the range by setting the `:custom_value_scale` option or `force_value_range/2` (deprecated)

  """

  import Contex.SVG

  alias __MODULE__
  alias Contex.{Scale, ContinuousLinearScale, OrdinalScale}
  alias Contex.CategoryColourScale
  alias Contex.{Dataset, Mapping}
  alias Contex.Axis
  alias Contex.Utils

  defstruct [
    :dataset,
    :mapping,
    :options,
    :category_scale,
    :value_scale,
    :series_fill_colours,
    :series_fill_colours_neg,
    :phx_event_handler,
    :value_range,
    :select_item
  ]

  @required_mappings [
     category_col: :exactly_one,
     type_col: :exactly_one,
     value_cols: :one_or_more
  ]

  @default_options [
    type: :stacked,
    orientation: :vertical,
    axis_label_rotation: :auto,
    custom_value_scale: nil,
    custom_value_formatter: nil,
    width: 100,
    height: 100,
    padding: 2,
    data_labels: true,
    colour_palette: :default,
    colour_palette_neg: :default,
    phx_event_handler: nil,
    phx_event_target: nil,
    select_item: nil
  ]

  @type t() :: %__MODULE__{}
  @type orientation() :: :vertical | :horizontal
  @type plot_type() :: :stacked | :grouped
  @type selected_item() :: %{category: any(), series: any()}

  @doc ~S"""
  Creates a new bridge from a dataset and sets defaults.

  Options may be passed to control the settings for the bridge. Options available are:

    - `:type` : `:stacked` (default) or `:grouped`
    - `:orientation` : `:vertical` (default) or `:horizontal`
    - `:axis_label_rotation` : `:auto` (default), 45 or 90

  Specifies the label rotation value that will be applied to the bottom axis. Accepts integer
  values for degrees of rotation or `:auto`. Note that manually set rotation values other than
  45 or 90 will be treated as zero. The default value is `:auto`, which sets the rotation to
  zero degrees if the number of items on the axis is greater than eight, 45 degrees otherwise.

    - `:custom_value_scale` : `nil` (default) or an instance of a suitable `Contex.Scale`.

    The scale must be suitable for the data type and would typically be `Contex.ContinuousLinearScale`.
    It is not necessary to set the range for the scale as the range is set
    as part of the chart layout process.

    - `:custom_value_formatter` : `nil` (default) or a function with arity 1

  Allows the axis tick labels to be overridden. For example, if you have a numeric representation of money and you want to
  have the value axis show it as millions of dollars you might do something like:

        # Turns 1_234_567.67 into $1.23M
        defp money_formatter_millions(value) when is_number(value) do
          "$#{:erlang.float_to_binary(value/1_000_000.0, [decimals: 2])}M"
        end

        defp show_chart(data) do
          Bridge.new(
            dataset,
            mapping: %{category_col: :column_a, value_cols: [:column_b, column_c]},
            custom_value_formatter: &money_formatter_millions/1
          )
        end

    - `:padding` : integer (default 2) - Specifies the padding between the category groups. Defaults to 2. Specified relative to the plot size.
    - `:data_labels` : `true` (default) or false - display labels for each bar value
    - `:colour_palette` : `:default` (default) or colour palette - see `colours/2`

  Overrides the default colours.

  Colours can either be a named palette defined in `Contex.CategoryColourScale` or a list of strings representing hex code
  of the colour as per CSS colour hex codes, but without the #. For example:

    ```
    bridge = Bridge.new(
        dataset,
        mapping: %{category_col: :column_a, value_cols: [:column_b, column_c]},
        colour_palette: ["fbb4ae", "b3cde3", "ccebc5"]
      )
    ```

    The colours will be applied to the data series in the same order as the columns are specified in `set_val_col_names/2`

    - `:phx_event_handler` : `nil` (default) or string representing `phx-click` event handler
    - `:phx_event_target` : `nil` (default) or string representing `phx-target` for handler

  Optionally specify a LiveView event handler. This attaches a `phx-click` attribute to each bar element.
  You can specify the event_target for LiveComponents - a `phx-target` attribute will also be attached.

  Note that it may not work with some browsers (e.g. Safari on iOS).

    - `:select_item` - optional selected item to highlight. See `select_item/2`.

    - `:mapping` : Maps attributes required to generate the bridge to columns in the dataset.

  If the data in the dataset is stored as a map, the `:mapping` option is required. If the dataset
  is not stored as a map, `:mapping` may be left out, in which case the first column will be used
  for the category and the second column used as the value.
  This value must be a map of the plot's `:category_col` and `:value_cols` to keys in the map,
  such as `%{category_col: :column_a, value_cols: [:column_b, column_c]}`.
  The value for the `:value_cols` key must be a list.
  """
  @spec new(Contex.Dataset.t(), keyword()) :: Contex.Bridge.t()
  def new(%Dataset{} = dataset, options \\ []) when is_list(options) do
    options = Keyword.merge(@default_options, options)
    mapping = Mapping.new(@required_mappings, Keyword.get(options, :mapping), dataset)

    %Bridge{
      dataset: dataset,
      mapping: mapping,
      options: options
    }
  end

  @doc """
  Sets the default scales for the plot based on its column mapping.
  """
  @deprecated "Default scales are now silently applied"
  @spec set_default_scales(Contex.Bridge.t()) :: Contex.Bridge.t()
  def set_default_scales(%Bridge{mapping: %{column_map: column_map}} = plot) do
    set_cat_col_name(plot, column_map.category_col)
    |> set_val_col_names(column_map.value_cols)
  end

  @doc """
  Specifies whether data labels are shown on the bars
  """
  @deprecated "Set in new/2 options"
  @spec data_labels(Contex.Bridge.t(), boolean()) :: Contex.Bridge.t()
  def data_labels(%Bridge{} = plot, data_labels) do
    set_option(plot, :data_labels, data_labels)
  end

  @doc """
  Specifies whether the bars are drawn stacked or grouped.
  """
  @deprecated "Set in new/2 options"
  @spec type(Contex.Bridge.t(), plot_type()) :: Contex.Bridge.t()
  def type(%Bridge{} = plot, type) do
    set_option(plot, :type, type)
  end

  @doc """
  Specifies whether the bars are drawn horizontally or vertically.
  """
  @deprecated "Set in new/2 options"
  @spec orientation(Contex.Bridge.t(), orientation()) :: Contex.Bridge.t()
  def orientation(%Bridge{} = plot, orientation) do
    set_option(plot, :orientation, orientation)
  end

  @doc """
  Forces the value scale to the given data range
  """
  @spec force_value_range(Contex.Bridge.t(), {number, number}) :: Contex.Bridge.t()
  @deprecated "Use the `:custom_value_scale` option in `new/2`"
  def force_value_range(%Bridge{mapping: mapping} = plot, {min, max} = value_range)
      when is_number(min) and is_number(max) do
    %{plot | value_range: value_range}
    |> set_val_col_names(mapping.column_map.value_cols)
  end

  @doc false
  def set_size(%Bridge{} = plot, width, height) do
    plot
    |> set_option(:width, width)
    |> set_option(:height, height)
  end

  @doc """
  Specifies the label rotation value that will be applied to the bottom axis. Accepts integer
  values for degrees of rotation or `:auto`. Note that manually set rotation values other than
  45 or 90 will be treated as zero. The default value is `:auto`, which sets the rotation to
  zero degrees if the number of items on the axis is greater than eight, 45 degrees otherwise.
  """
  @deprecated "Set in new/2 options"
  @spec axis_label_rotation(Contex.Bridge.t(), integer() | :auto) :: Contex.Bridge.t()
  def axis_label_rotation(%Bridge{} = plot, rotation) when is_integer(rotation) do
    set_option(plot, :axis_label_rotation, rotation)
  end

  def axis_label_rotation(%Bridge{} = plot, _) do
    set_option(plot, :axis_label_rotation, :auto)
  end

  @doc """
  Specifies the padding between the category groups. Defaults to 2. Specified relative to the plot size.
  """
  @deprecated "Set in new/2 options"
  @spec padding(Contex.Bridge.t(), number) :: Contex.Bridge.t()
  def padding(%Bridge{} = plot, padding) when is_number(padding) do
    set_option(plot, :padding, padding)
  end

  @doc """
  Overrides the default colours.

  Colours can either be a named palette defined in `Contex.CategoryColourScale` or a list of strings representing hex code
  of the colour as per CSS colour hex codes, but without the #. For example:

    ```
    bridge = Bridge.colours(bridge, ["fbb4ae", "b3cde3", "ccebc5"])
    ```

    The colours will be applied to the data series in the same order as the columns are specified in `set_val_col_names/2`
  """
  @deprecated "Set in new/2 options"
  @spec colours(Contex.Bridge.t(), Contex.CategoryColourScale.colour_palette()) ::
          Contex.Bridge.t()
  def colours(%Bridge{} = plot, colour_palette) when is_list(colour_palette) do
    set_option(plot, :colour_palette, colour_palette)
  end

  def colours(%Bridge{} = plot, colour_palette) when is_atom(colour_palette) do
    set_option(plot, :colour_palette, colour_palette)
  end

  def colours(%Bridge{} = plot, _) do
    set_option(plot, :colour_palette, :default)
  end

  @doc """
  Optionally specify a LiveView event handler. This attaches a `phx-click` attribute to each bar element.
  You can specify the event_target for LiveComponents - a `phx-target` attribute will also be attached.

  Note that it may not work with some browsers (e.g. Safari on iOS).
  """
  @deprecated "Set in new/2 options"
  def event_handler(%Bridge{} = plot, event_handler, event_target \\ nil) do
    plot
    |> set_option(:phx_event_handler, event_handler)
    |> set_option(:phx_event_target, event_target)
  end

  defp set_option(%Bridge{options: options} = plot, key, value) do
    options = Keyword.put(options, key, value)

    %{plot | options: options}
  end

  defp get_option(%Bridge{options: options}, key) do
    Keyword.get(options, key)
  end

  @doc """
  Highlights a selected value based on matching category and series.
  """
  @spec select_item(Contex.Bridge.t(), selected_item()) :: Contex.Bridge.t()
  def select_item(%Bridge{} = plot, select_item) do
    set_option(plot, :select_item, select_item)
  end

  @doc ~S"""
  Allows the axis tick labels to be overridden. For example, if you have a numeric representation of money and you want to
  have the value axis show it as millions of dollars you might do something like:

        # Turns 1_234_567.67 into $1.23M
        defp money_formatter_millions(value) when is_number(value) do
          "$#{:erlang.float_to_binary(value/1_000_000.0, [decimals: 2])}M"
        end

        defp show_chart(data) do
          Bridge.new(data)
          |> Bridge.custom_value_formatter(&money_formatter_millions/1)
        end

  """
  @spec custom_value_formatter(Contex.Bridge.t(), nil | fun) :: Contex.Bridge.t()
  @deprecated "Set in new/2 options"
  def custom_value_formatter(%Bridge{} = plot, custom_value_formatter)
      when is_function(custom_value_formatter) or custom_value_formatter == nil do
    set_option(plot, :custom_value_formatter, custom_value_formatter)
  end

  @doc false
  def get_legend_scales(%Bridge{options: options} = plot) do
    plot = prepare_scales(plot)
    scale = plot.series_fill_colours

    orientation = Keyword.get(options, :orientation)
    type = Keyword.get(options, :type)

    invert = orientation == :vertical and type == :stacked

    scale =
      if invert do
        CategoryColourScale.invert(scale)
      else
        scale
      end

    [scale]
  end

  @doc false
  def to_svg(%Bridge{options: options} = plot, plot_options) do
    # TODO: Some kind of option validation before removing deprecated option functions
    plot = prepare_scales(plot)
    category_scale = plot.category_scale
    value_scale = plot.value_scale

    orientation = Keyword.get(options, :orientation)
    plot_options = refine_options(plot_options, orientation)

    category_axis = get_category_axis(category_scale, orientation, plot)

    value_axis = get_value_axis(value_scale, orientation, plot)
    plot = %{plot | value_scale: value_scale, select_item: get_option(plot, :select_item)}

    cat_axis_svg = if plot_options.show_cat_axis, do: Axis.to_svg(category_axis), else: ""

    val_axis_svg = if plot_options.show_val_axis, do: Axis.to_svg(value_axis), else: ""

    [
      cat_axis_svg,
      val_axis_svg,
      "<g>",
      get_svg_bars(plot),
      "</g>"
    ]
  end

  defp refine_options(options, :horizontal),
    do:
      options
      |> Map.put(:show_cat_axis, options.show_y_axis)
      |> Map.put(:show_val_axis, options.show_x_axis)

  defp refine_options(options, _),
    do:
      options
      |> Map.put(:show_cat_axis, options.show_x_axis)
      |> Map.put(:show_val_axis, options.show_y_axis)

  defp get_category_axis(category_scale, :horizontal, plot) do
    Axis.new_left_axis(category_scale) |> Axis.set_offset(get_option(plot, :width))
  end

  defp get_category_axis(category_scale, _, plot) do
    rotation =
      case get_option(plot, :axis_label_rotation) do
        :auto ->
          if length(Scale.ticks_range(category_scale)) > 8, do: 45, else: 0

        degrees ->
          degrees
      end

    category_scale
    |> Axis.new_bottom_axis()
    |> Axis.set_offset(get_option(plot, :height))
    |> Kernel.struct(rotation: rotation)
  end

  defp get_value_axis(value_scale, :horizontal, plot),
    do: Axis.new_bottom_axis(value_scale) |> Axis.set_offset(get_option(plot, :height))

  defp get_value_axis(value_scale, _, plot),
    do: Axis.new_left_axis(value_scale) |> Axis.set_offset(get_option(plot, :width))

  defp get_svg_bars(%Bridge{mapping: %{column_map: column_map}, dataset: dataset} = plot) do
    series_fill_colours = plot.series_fill_colours
    series_fill_colours_neg = plot.series_fill_colours_neg

    fills =
      Enum.map(column_map.value_cols, fn column ->
        CategoryColourScale.colour_for_value(series_fill_colours, column)
      end)

    fills_neg =
      Enum.map(column_map.value_cols, fn column ->
        CategoryColourScale.colour_for_value(series_fill_colours_neg, column)
      end)

    {bars, _} = dataset.data
    |> Enum.map_reduce(0, fn row, acc -> get_svg_bar(acc, row, plot, fills, fills_neg) end)

    bars
  end

  defp get_svg_bar(
	 start,
         row,
         %Bridge{mapping: mapping, category_scale: category_scale, value_scale: value_scale} =
           plot,
         fills, fills_neg
       ) do
    cat_data = mapping.accessors.category_col.(row)
    bar_type = mapping.accessors.type_col.(row)
    series_values = Enum.map(mapping.accessors.value_cols, fn value_col -> value_col.(row) end)

    delta = if bar_type == :sum, do: 0, else: start
    
    cat_band = OrdinalScale.get_band(category_scale, cat_data)
    bar_values = prepare_bar_values(series_values, value_scale, get_option(plot, :type))
    labels = Enum.map(series_values, fn val -> Scale.get_formatted_tick(value_scale, val) end)
    event_handlers = get_bar_event_handlers(plot, cat_data, series_values)
    opacities = get_bar_opacities(plot, cat_data)

    y_increase =
      bar_values
      |> Enum.reduce(delta, fn {y1, y2}, acc -> (y1-y2) + acc end)

    {get_svg_bar_rects(delta, cat_band, bar_values, labels, plot, fills, fills_neg, event_handlers, opacities), y_increase}
  end

  defp get_bar_event_handlers(%Bridge{mapping: mapping} = plot, category, series_values) do
    handler = get_option(plot, :phx_event_handler)
    target = get_option(plot, :phx_event_target)

    base_opts =
      case target do
        nil -> [phx_click: handler]
        "" -> [phx_click: handler]
        _ -> [phx_click: handler, phx_target: target]
      end

    case handler do
      nil ->
        Enum.map(mapping.column_map.value_cols, fn _ -> [] end)

      "" ->
        Enum.map(mapping.column_map.value_cols, fn _ -> [] end)

      _ ->
        Enum.zip(mapping.column_map.value_cols, series_values)
        |> Enum.map(fn {col, value} ->
          Keyword.merge(base_opts, category: category, series: col, value: value)
        end)
    end
  end

  @bar_faded_opacity "0.3"
  defp get_bar_opacities(
         %Bridge{
           select_item: %{category: selected_category, series: _selected_series},
           mapping: mapping
         },
         category
       )
       when selected_category != category do
    Enum.map(mapping.column_map.value_cols, fn _ -> @bar_faded_opacity end)
  end

  defp get_bar_opacities(
         %Bridge{
           select_item: %{category: _selected_category, series: selected_series},
           mapping: mapping
         },
         _category
       ) do
    Enum.map(mapping.column_map.value_cols, fn col ->
      case col == selected_series do
        true -> ""
        _ -> @bar_faded_opacity
      end
    end)
  end

  defp get_bar_opacities(%Bridge{mapping: mapping}, _) do
    Enum.map(mapping.column_map.value_cols, fn _ -> "" end)
  end

  # Transforms the raw value for each series into a list of range tuples the bar has to cover, scaled to the display area
  defp prepare_bar_values(series_values, scale, :stacked) do
    {results, _last_val} =
      Enum.reduce(series_values, {[], 0}, fn data_val, {points, last_val} ->
        end_val = data_val + last_val
        new = {Scale.domain_to_range(scale, last_val), Scale.domain_to_range(scale, end_val)}
        {[new | points], end_val}
      end)

    Enum.reverse(results)
  end

  defp prepare_bar_values(series_values, scale, :grouped) do
    {scale_min, _} = Scale.get_range(scale)

    results =
      Enum.reduce(series_values, [], fn data_val, points ->
        range_val = Scale.domain_to_range(scale, data_val)
        [{scale_min, range_val} | points]
      end)

    Enum.reverse(results)
  end

  defp get_svg_bar_rects(
	 start,
         {cat_band_min, cat_band_max} = cat_band,
         bar_values,
         labels,
         plot,
         fills,
	 fills_neg,
         event_handlers,
         opacities
       )
       when is_number(cat_band_min) and is_number(cat_band_max) do
    count = length(bar_values)
    indices = 0..(count - 1)

    orientation = get_option(plot, :orientation)

    adjusted_bands =
      Enum.map(indices, fn index ->
        adjust_cat_band(cat_band, index, count, get_option(plot, :type), orientation)
      end)

    rects =
      Enum.zip([bar_values, fills, fills_neg, labels, adjusted_bands, event_handlers, opacities])
      |> Enum.map(fn {bar_value, fill, fill_neg, label, adjusted_band, event_opts, opacity} ->
        {x, {y1, y2}} = get_bar_rect_coords(orientation, adjusted_band, bar_value)
	fill = if y1-y2 < 0, do: fill_neg, else: fill

        opts = [fill: fill, opacity: opacity] ++ event_opts

        rect(x, {y1-start, y2-start}, title(label), opts)
      end)

    texts =
      case count < 4 and get_option(plot, :data_labels) do
        false ->
          []

        _ ->
          Enum.zip([bar_values, labels, adjusted_bands])
          |> Enum.map(fn {bar_value, label, adjusted_band} ->
	    {x, y} = adjusted_band
	    {x1, y1} = bar_value
            get_svg_bar_label(orientation, {x1 - start, y1 - start}, label, {x, y}, plot)
          end)
      end

    # TODO: Get nicer text with big stacks - maybe limit to two series
    [rects, texts]
  end

  defp get_svg_bar_rects(_x, _y, _label, _plot, _fill, _fill_neg, _event_handlers, _opacities), do: ""

  defp adjust_cat_band(cat_band, _index, _count, :stacked, _), do: cat_band

  defp adjust_cat_band({cat_band_start, cat_band_end}, index, count, :grouped, :vertical) do
    interval = (cat_band_end - cat_band_start) / count
    {cat_band_start + index * interval, cat_band_start + (index + 1) * interval}
  end

  defp adjust_cat_band({cat_band_start, cat_band_end}, index, count, :grouped, :horizontal) do
    interval = (cat_band_end - cat_band_start) / count
    # Flip index so that first series is at top of group
    index = count - index - 1
    {cat_band_start + index * interval, cat_band_start + (index + 1) * interval}
  end

  defp get_bar_rect_coords(:horizontal, cat_band, bar_extents), do: {bar_extents, cat_band}
  defp get_bar_rect_coords(:vertical, cat_band, bar_extents), do: {cat_band, bar_extents}

  defp get_svg_bar_label(:horizontal, {_, bar_end} = bar, label, cat_band, _plot) do
    text_y = midpoint(cat_band)
    width = width(bar)

    {text_x, class, anchor} =
      case width < 50 do
        true -> {bar_end + 2, "exc-barlabel-out", "start"}
        _ -> {midpoint(bar), "exc-barlabel-in", "middle"}
      end

    text(text_x, text_y, label, text_anchor: anchor, class: class, dominant_baseline: "central")
  end

  defp get_svg_bar_label(_, {bar_start, _} = bar, label, cat_band, _plot) do
    text_x = midpoint(cat_band)

    {text_y, class} =
      case width(bar) > 20 do
        true -> {midpoint(bar) + 5, "exc-barlabel-in"}
        _ ->
	  if bar_start - 25 > 0 do
	    {bar_start - 25, "exc-barlabel-out"}
	  else
	    {bar_start + width(bar) + 25, "exc-barlabel-out"}
	  end
      end

    text(text_x, text_y, label, text_anchor: "middle", class: class)
  end

  @doc """
  Sets the category column name. This must exist in the dataset.

  This provides the labels for each bar or group of bars
  """
  @deprecated "Use `:mapping` option in `new/2`"
  def set_cat_col_name(%Bridge{mapping: mapping} = plot, cat_col_name) do
    mapping = Mapping.update(mapping, %{category_col: cat_col_name})

    %{plot | mapping: mapping}
  end

  @doc """
  Sets the value column names. Each must exist in the dataset.

  This provides the value for each bar.
  """
  @deprecated "Use `:mapping` option in `new/2`"
  def set_val_col_names(%Bridge{mapping: mapping} = plot, val_col_names)
      when is_list(val_col_names) do
    mapping = Mapping.update(mapping, %{value_cols: val_col_names})

    %{plot | mapping: mapping}
  end

  def set_val_col_names(%Bridge{} = plot, _), do: plot

  defp prepare_scales(%Bridge{} = plot) do
    plot
    |> prepare_value_scale()
    |> prepare_category_scale()
    |> prepare_colour_scale()
  end

  defp prepare_category_scale(
         %Bridge{dataset: dataset, options: options, mapping: mapping} = plot
       ) do
    padding = Keyword.get(options, :padding, 2)

    cat_col_name = mapping.column_map[:category_col]
    categories = Dataset.unique_values(dataset, cat_col_name)
    {r_min, r_max} = get_range(:category, plot)

    cat_scale =
      OrdinalScale.new(categories)
      |> Scale.set_range(r_min, r_max)
      |> OrdinalScale.padding(padding)

    %{plot | category_scale: cat_scale}
  end

  defp prepare_value_scale(%Bridge{dataset: dataset, mapping: mapping} = plot) do
    val_col_names = mapping.column_map[:value_cols]
    custom_value_scale = get_option(plot, :custom_value_scale)

    val_scale =
      case custom_value_scale do
        nil ->
          {min, max} =
            get_overall_value_domain(plot, dataset, val_col_names, get_option(plot, :type))
            |> Utils.fixup_value_range()

          ContinuousLinearScale.new()
          |> ContinuousLinearScale.domain(min, max)
          |> struct(custom_tick_formatter: get_option(plot, :custom_value_formatter))

        _ ->
          custom_value_scale
      end

    {r_start, r_end} = get_range(:value, plot)
    val_scale = Scale.set_range(val_scale, r_start, r_end)

    %{plot | value_scale: val_scale, mapping: mapping}
  end

  defp prepare_colour_scale(%Bridge{mapping: mapping} = plot) do
    val_col_names = mapping.column_map[:value_cols]

    series_fill_colours =
      CategoryColourScale.new(val_col_names)
      |> CategoryColourScale.set_palette(get_option(plot, :colour_palette))

    series_fill_colours_neg =
      CategoryColourScale.new(val_col_names)
      |> CategoryColourScale.set_palette(get_option(plot, :colour_palette_neg))
    
    %{plot | series_fill_colours: series_fill_colours, series_fill_colours_neg: series_fill_colours_neg, mapping: mapping}
  end

  defp get_range(:category, %Bridge{} = plot) do
    case get_option(plot, :orientation) do
      :horizontal -> {get_option(plot, :height), 0}
      _ -> {0, get_option(plot, :width)}
    end
  end

  defp get_range(:value, %Bridge{} = plot) do
    case get_option(plot, :orientation) do
      :horizontal -> {0, get_option(plot, :width)}
      _ -> {get_option(plot, :height), 0}
    end
  end

  defp get_overall_value_domain(%Bridge{value_range: {min, max}}, _, _, _), do: {min, max}

  defp get_overall_value_domain(_plot, dataset, col_names, :stacked) do
    {_, max} = Dataset.combined_column_extents(dataset, col_names)
    {0, max}
  end

  defp get_overall_value_domain(_plot, dataset, col_names, :grouped) do
    combiner = fn {min1, max1}, {min2, max2} ->
      {Utils.safe_min(min1, min2), Utils.safe_max(max1, max2)}
    end

    Enum.reduce(col_names, {nil, nil}, fn col, acc_extents ->
      inner_extents = Dataset.column_extents(dataset, col)
      combiner.(acc_extents, inner_extents)
    end)
  end

  defp midpoint({a, b}), do: (a + b) / 2.0
  defp width({a, b}), do: abs(a - b)
end
