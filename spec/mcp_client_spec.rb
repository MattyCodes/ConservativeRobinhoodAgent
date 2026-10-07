# frozen_string_literal: true

require_relative "spec_helper"

describe McpClient do
  it "follows tools/list pagination until there is no nextCursor" do
    client = McpClient.new(url: "https://example.invalid/mcp")
    pages = [{ "tools" => [{ "name" => "a" }], "nextCursor" => "c1" }, { "tools" => [{ "name" => "b" }] }]
    seen = []

    names = client.stub(:ensure_initialized, nil) do
      client.stub(:rpc, ->(method, params) { seen << [method, params]; pages.shift }) do
        client.list_tools.map { |t| t["name"] }
      end
    end

    _(names).must_equal %w[a b]
    _(seen).must_equal [["tools/list", {}], ["tools/list", { cursor: "c1" }]]
  end
end
