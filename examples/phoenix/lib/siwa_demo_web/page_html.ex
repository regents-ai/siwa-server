defmodule SiwaDemoWeb.PageHTML do
  @moduledoc false

  import Phoenix.Template, only: [embed_templates: 1]

  embed_templates "page_html/*"
end
