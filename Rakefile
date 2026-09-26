# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:spec) do |t|
  t.libs << "lib" << "spec"
  t.test_files = FileList["spec/*_spec.rb"]
  t.warning = false
end

task default: :spec
