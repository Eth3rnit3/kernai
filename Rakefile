require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

Rake::TestTask.new(:test_unit) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/kernai/test_*.rb"]
end

Rake::TestTask.new(:test_examples) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/examples/test_*.rb"]
end

desc "Re-record VCR cassettes (requires OPENAI_API_KEY and/or ANTHROPIC_API_KEY)"
task :vcr_record do
  ENV["VCR_RECORD"] = "all"
  Rake::Task[:test_examples].invoke
end

task default: :test
