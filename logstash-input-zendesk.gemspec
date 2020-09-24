Gem::Specification.new do |s|
  s.name          = 'logstash-input-zendesk'
  s.version       = '0.1.0'
  s.licenses      = ['Apache-2.0']
  s.summary       = 'Zendesk input plugin for Logstash'
  s.description   = 'This gem together with Logstash provides an input pipe from Zendesk into Elasticsearch to insert Zendesk tickets details, comments and other Zendesk info into the Elasticsearch indexes.'
  s.homepage      = 'https://github.com/sejba/logstash-input-zendesk'
  s.authors       = ['ppf2','Jakub Sejba']
  s.email         = 'sejba@jsejba.cz'
  s.require_paths = ['lib']

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "input" }

  # Gem dependencies
  s.add_runtime_dependency "logstash-core-plugin-api", "~> 2.0"
  s.add_runtime_dependency 'logstash-codec-plain'
  s.add_runtime_dependency 'stud', '>= 0.0.22'
  s.add_runtime_dependency 'zendesk_api', '>= 1.27.0'
  s.add_development_dependency 'logstash-devutils', '>= 0.0.16'
end
