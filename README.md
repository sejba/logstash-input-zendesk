# Logstash Input Plugin for Zendesk

This is an input plugin for [Logstash](https://github.com/elastic/logstash). It fatches the data from Zendesk and creates Logstash events to be inserted into Elasticsearch indexes.
The early versions were heavily based on [this plugin](https://github.com/ppf2/logstash-input-zendesk), which hasn't been worked on since aprox 2015. Several blocks of the source code are 100% copy-pasted. Thank you PPF2. Other parts had to be slightly rewritten due to the latest changes in Logstash and Zendesk API. Some parts of the original source code have been removed completely as I have no use for them.

To access Zendesk the official Zendesk's [Ruby gem](https://github.com/zendesk/zendesk_api_client_rb) is used. 

This plugin is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it however you want in whatever way.

## Installation

## Configuration 

## Documentation

