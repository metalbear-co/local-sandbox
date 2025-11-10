package k8s

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

type Client struct {
	clientset     *kubernetes.Clientset
	dynamicClient dynamic.Interface
}

func NewClient() (*Client, error) {
	config, err := getConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to get kubernetes config: %w", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes clientset: %w", err)
	}

	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	return &Client{
		clientset:     clientset,
		dynamicClient: dynamicClient,
	}, nil
}

func getConfig() (*rest.Config, error) {
	config, err := rest.InClusterConfig()
	if err == nil {
		return config, nil
	}

	loadingRules := clientcmd.NewDefaultClientConfigLoadingRules()
	configOverrides := &clientcmd.ConfigOverrides{}
	kubeConfig := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loadingRules, configOverrides)
	return kubeConfig.ClientConfig()
}

func (c *Client) GetPod(ctx context.Context, namespace, labelSelector string) (*corev1.Pod, error) {
	pods, err := c.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: labelSelector,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list pods: %w", err)
	}

	if len(pods.Items) == 0 {
		return nil, fmt.Errorf("no pods found with selector: %s", labelSelector)
	}

	// Filter out job pods - we only want database pods (those without the "job-name" label)
	for _, pod := range pods.Items {
		if pod.Labels != nil {
			if _, hasJobLabel := pod.Labels["job-name"]; !hasJobLabel {
				return &pod, nil
			}
		}
	}

	return nil, fmt.Errorf("no non-job pods found with selector: %s", labelSelector)
}

func (c *Client) WaitForNamespaceDeletion(ctx context.Context, namespace string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	attempt := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			attempt++
			_, err := c.clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
			if err != nil {
				return nil
			}

			fmt.Printf("Waiting for namespace deletion... (%d)\n", attempt)

			if time.Now().After(deadline) {
				return fmt.Errorf("timeout waiting for namespace %s to be deleted", namespace)
			}
		}
	}
}

func (c *Client) WaitForPodReady(ctx context.Context, namespace, labelSelector string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			pod, err := c.GetPod(ctx, namespace, labelSelector)
			if err != nil {
				if time.Now().After(deadline) {
					return fmt.Errorf("timeout waiting for pod with selector %s: %w", labelSelector, err)
				}
				continue
			}

			for _, condition := range pod.Status.Conditions {
				if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
					return nil
				}
			}

			if time.Now().After(deadline) {
				return fmt.Errorf("timeout waiting for pod %s to be ready", pod.Name)
			}
		}
	}
}

// IsBranchDatabaseReady checks if a branch database CR has status phase Ready
func (c *Client) IsBranchDatabaseReady(ctx context.Context, namespace, branchName, kind string) (bool, error) {
	// Get the custom resource
	gvr := schema.GroupVersionResource{
		Group:   "dbs.mirrord.metalbear.co",
		Version: "v1alpha1",
	}

	// Set resource name based on kind
	if kind == "MysqlBranchDatabase" {
		gvr.Resource = "mysqlbranchdatabases"
	} else if kind == "PgBranchDatabase" {
		gvr.Resource = "pgbranchdatabases"
	} else {
		return false, fmt.Errorf("unsupported kind: %s", kind)
	}

	obj, err := c.dynamicClient.Resource(gvr).Namespace(namespace).Get(ctx, branchName, metav1.GetOptions{})
	if err != nil {
		return false, err
	}

	// Extract status.phase
	status, found, err := unstructured.NestedString(obj.Object, "status", "phase")
	if err != nil {
		return false, fmt.Errorf("error reading status.phase: %w", err)
	}
	if !found {
		return false, nil
	}

	return status == "Ready", nil
}
