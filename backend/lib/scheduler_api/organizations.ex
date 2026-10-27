defmodule SchedulerApi.Organizations do
  @moduledoc "Tenant identity and explicit default-shop resolution; no authorization yet."
  alias SchedulerApi.Repo
  alias SchedulerApi.Organizations.{Business, Shop}

  def default_business! do
    Repo.get_by!(Business, slug: "magnum-detailing")
  end

  @doc "Resolves the public booking shop by known business/shop slugs, never by row order or caller attrs."
  def default_shop! do
    business = default_business!()
    Repo.get_by!(Shop, business_id: business.id, slug: "default")
  end
end
