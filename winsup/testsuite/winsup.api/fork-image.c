/* Exercise image-address-dependent state and thread creation after fork.
   Run with forced ASLR as well as without it to cover image realignment. */

#define _WIN32_WINNT 0x0a00

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include <windows.h>

static volatile int data_value = 31;
static volatile int bss_value;

static int
read_data (void)
{
  return data_value + bss_value;
}

static int (*volatile function_pointer) (void) = read_data;

static void *
worker (void *arg)
{
  int *value = arg;
  assert (*value == 47);
  *value = 53;
  return arg;
}

int
main (void)
{
  volatile int stack_value = 19;
  volatile int *volatile stack_pointer = &stack_value;
  int *heap_pointer = malloc (sizeof (*heap_pointer));
  HMODULE image = GetModuleHandleW (NULL);
  PROCESS_MITIGATION_ASLR_POLICY policy;
  assert (heap_pointer);
  *heap_pointer = 47;
  bss_value = 37;
  assert (GetProcessMitigationPolicy (GetCurrentProcess (), ProcessASLRPolicy,
                                     &policy, sizeof (policy)));

  for (int i = 0; i < 8; ++i)
    {
      pid_t child = fork ();
      assert (child >= 0);
      if (!child)
        {
          PROCESS_MITIGATION_ASLR_POLICY child_policy;
          assert (GetModuleHandleW (NULL) == image);
          assert (GetProcessMitigationPolicy (GetCurrentProcess (),
                                             ProcessASLRPolicy, &child_policy,
                                             sizeof (child_policy)));
          assert (child_policy.Flags == policy.Flags);
          assert (function_pointer () == 68);
          assert (stack_pointer == &stack_value && *stack_pointer == 19);
          assert (*heap_pointer == 47);

          pthread_t thread;
          void *returned;
          assert (!pthread_create (&thread, NULL, worker, heap_pointer));
          assert (!pthread_join (thread, &returned));
          assert (returned == heap_pointer && *heap_pointer == 53);

          pid_t grandchild = fork ();
          assert (grandchild >= 0);
          if (!grandchild)
            {
              assert (function_pointer () == 68 && *heap_pointer == 53);
              _exit (23);
            }
          int status;
          assert (waitpid (grandchild, &status, 0) == grandchild);
          assert (WIFEXITED (status) && WEXITSTATUS (status) == 23);
          _exit (17);
        }
      int status;
      assert (waitpid (child, &status, 0) == child);
      assert (WIFEXITED (status) && WEXITSTATUS (status) == 17);
      assert (*heap_pointer == 47 && function_pointer () == 68);
    }

  free (heap_pointer);
  printf ("fork-image: passed; parent ASLR flags=%lu\n",
          (unsigned long) policy.Flags);
  return 0;
}
