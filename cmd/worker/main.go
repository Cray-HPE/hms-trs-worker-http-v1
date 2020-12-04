// Copyright 2020 Cray, Inc.

package main

// This is for manual testing only, not to be used in the library package.

import (
	"context"
	"encoding/json"
	"github.com/Shopify/sarama"
	"github.com/sirupsen/logrus"
	"io/ioutil"
	"os"
	"os/signal"
	trsapi "stash.us.cray.com/HMS/hms-trs-app-api/pkg/trs_http_api"
	tkafka "stash.us.cray.com/HMS/hms-trs-kafkalib/pkg/trs-kafkalib"
	"strings"
	"time"

	topics "stash.us.cray.com/HMS/hms-trs-operator/pkg/kafka_topics"
	"sync"
	"syscall"
)

var wk Worker

type Worker struct {
	svcName                     string
	sender                      string
	brokerSpec                  string
	kafkaRspChan                chan *sarama.ConsumerMessage
	stopUpdateTopics            chan []byte
	updateTopicsRefreshInterval int
	kafkaInstance               *tkafka.TRSKafka
	consumerGroup               string
	waitGroup                   sync.WaitGroup
	tloc                        trsapi.TRSHTTPLocal
	topicsFile                  string
}

func SpawnHttpTask(httpTask trsapi.HttpTask) {
	tsks := []trsapi.HttpTask{httpTask}
	taskChannel, err := wk.tloc.Launch(&tsks)

	if err != nil {
		logrus.Error(err)
	}

	returnedHttpTask := <-taskChannel
	logrus.Debugf("returned task: %+v", returnedHttpTask)
	returnPayload := returnedHttpTask.ToHttpKafkaRx()
	responseData, err := json.Marshal(returnPayload)
	if err != nil {
		logrus.Errorf("Failed to marshall RxTask: %s", err)
	} else {
		_, receiveTopic, _ := tkafka.GenerateSendReceiveConsumerGroupName(httpTask.ServiceName, "http-v1", "")
		wk.kafkaInstance.Write(receiveTopic, responseData)
		logrus.Debugf("Transmitted return message: %s", responseData)
	}
}

func main() {
	//SIGNAL HANDLING
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-c
		close(wk.stopUpdateTopics)
		close(wk.kafkaRspChan)
		wk.kafkaInstance.Shutdown()
	}()

	appAPILogger := logrus.New()
	kafkaLogger := logrus.New()
	kafkaLogger.SetLevel(logrus.ErrorLevel)
	appAPILogger.SetLevel(logrus.TraceLevel)

	envstr := os.Getenv("LOG_LEVEL")
	if envstr != "" {
		logLevel := strings.ToUpper(envstr)
		logrus.Infof("Setting log level to: %d\n", envstr)

		switch logLevel {

		case "TRACE":
			logrus.SetLevel(logrus.TraceLevel)
		case "DEBUG":
			logrus.SetLevel(logrus.DebugLevel)
		case "INFO":
			logrus.SetLevel(logrus.InfoLevel)
		case "WARN":
			logrus.SetLevel(logrus.WarnLevel)
		case "ERROR":
			logrus.SetLevel(logrus.ErrorLevel)
		case "FATAL":
			logrus.SetLevel(logrus.FatalLevel)
		case "PANIC":
			logrus.SetLevel(logrus.PanicLevel)
		default:
			logrus.SetLevel(logrus.ErrorLevel)
		}
	}

	logrus.SetLevel(logrus.TraceLevel)
	wk.svcName = "HTTP-Worker"
	wk.sender = "number1"
	wk.brokerSpec = "kafka:9092"
	envstr = os.Getenv("BROKER_SPEC")
	if envstr != "" {
		wk.brokerSpec = envstr
	}

	envstr = os.Getenv("TOPICS_FILE")
	if envstr != "" {
		wk.topicsFile = envstr
	} else {
		wk.topicsFile = "configs/active_topics.json"
	}

	wk.tloc.Init("Worker", appAPILogger)

	wk.updateTopicsRefreshInterval = 5
	wk.stopUpdateTopics = make(chan []byte)
	wk.kafkaRspChan = make(chan *sarama.ConsumerMessage)
	wk.kafkaInstance = &tkafka.TRSKafka{}

	//This makes the send topic / return topic global for the instance of the TRSHTTPRemote obj.
	file, _ := ioutil.ReadFile(wk.topicsFile)
	kts := []topics.KafkaTopic{}
	err := json.Unmarshal([]byte(file), &kts)
	if err != nil {
		logrus.Errorf("Failed to set topics, encountered unmarshal error: %s, falling back to null-list", err)
	}
	var receiveTopics []string

	for _, val := range kts {
		receiveTopics = append(receiveTopics, val.TopicName)
	}
	if len(receiveTopics) == 0 {
		receiveTopics = append(receiveTopics, "null-list")
	}

	consumerGroup := "http"
	logrus.Debugf("Set kafka listen topics to: %s", receiveTopics)

	err = wk.kafkaInstance.Init(context.TODO(), receiveTopics, consumerGroup, wk.brokerSpec, wk.kafkaRspChan, kafkaLogger)
	if err != nil {
		logrus.Error(err)
	}
	wk.waitGroup.Add(1)


	// Main PULLOFF Kafka Func
	go func() {
		defer wk.waitGroup.Done()
		var txTask trsapi.HttpKafkaTx
		for {
			select {
			//This was a MAJOR PAIN!!! : https://stackoverflow.com/questions/3398490/checking-if-a-channel-has-a-ready-to-read-value-using-go
			case consumerMessage, ok := <-wk.kafkaRspChan:


				if ok {
					raw := consumerMessage.Value
					logrus.Debugf("RECEIVED: '%s'", string(raw))
					err := json.Unmarshal(raw, &txTask)
					if err != nil {
						logrus.Errorf("ERROR unmarshaling received data: %v\n", err)
						continue
					}
					logrus.Debugf("LAUNCHING: '%v'", txTask)
					httpTask := txTask.ToHttpTask()
					go SpawnHttpTask(httpTask)
				} else {
					logrus.Infof("Kafka Response Channel closed! Exiting Go Routine")
					return
				}
			}
		}
	}()

	wk.waitGroup.Add(1)

	//Refresh Topics Func
	go func() {
		defer wk.waitGroup.Done()
		for {
			select {
			case _, ok := <-wk.stopUpdateTopics:
				if !ok {
					logrus.Infof("Stop updating topics! Exiting Go Routine")
					return
				}
			case <-time.After(time.Duration(wk.updateTopicsRefreshInterval) * time.Second):
				file, _ := ioutil.ReadFile(wk.topicsFile)
				kts := []topics.KafkaTopic{}
				err := json.Unmarshal([]byte(file), &kts)
				if err != nil {
					logrus.Errorf("Failed to update topics, encountered unmarshal error: %s", err)
					continue
				}
				var receiveTopics []string

				for _, val := range kts {
					receiveTopics = append(receiveTopics, val.TopicName)
				}

				if len(receiveTopics) == 0 {
					logrus.Warn("topics list cannot be 0, not updating topics")
					continue
				}
				err = wk.kafkaInstance.SetTopics(receiveTopics)
				if err != nil {
					logrus.Errorf("Failed to update topics, encountered SetTopics error: %s", err)
				} else {
					logrus.Debugf("Set kafka listen topics to: %s", receiveTopics)
				}
				continue
			}
		}
	}()

	wk.waitGroup.Wait()
	os.Exit(0)
}
