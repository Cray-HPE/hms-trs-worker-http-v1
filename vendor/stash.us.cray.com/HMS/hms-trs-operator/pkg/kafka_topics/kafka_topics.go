// Copyright 2020 Cray Inc. All Rights Reserved.

package kafka_topics

type KafkaTopic struct {
	TopicName    string   `json:"topicName,omitempty"`
	TopicOptions struct{} `json:"topicOptions,omitempty"`
}
