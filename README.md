# Lab 05 – Continuous Integration Pipeline

Welcome to the Continuous Integration (CI) Pipeline lab. In this exercise, you will design and execute an automated pipeline that validates code changes on every commit using GitHub Actions.

![alt divider](assets/gradient-fade-center-steps.svg)

|                                                                     Key take-away                                                                    |
| :--------------------------------------------------------------------------------------------------------------------------------------------------: |
| Continuous Integration treats every code change as a testable event, enforcing quality, consistency, and early failure detection through automation. |
|                                                                                                                                                      |

![alt divider](assets/gradient-fade-center-steps.svg)

This exercise is part two of three in the **Build Automation Fundamentals** portion of this class. Labs 4, 5, and 6 focus on automating validation, deployment readiness, and operational consistency. Together, these labs establish the foundation for reliable delivery pipelines used in modern DevOps environments.

## Overview

This repository introduces the fundamentals of **Continuous Integration** using GitHub Actions. You will configure an automated pipeline that triggers on source control events and executes validation steps without manual intervention.

In this lab, you must keep in mind that:

* Code is not considered “ready” until it passes automated checks.
* Automation replaces manual verification steps.
* Pipelines provide fast feedback and prevent broken changes from progressing.

## Key Concepts

This lab introduces the core principles behind Continuous Integration and automated quality control. You will connect source control activity to pipeline execution, ensuring that every change is validated in a consistent and repeatable manner.

Through this exercise, keep in mind the following:

* **Pipelines are Event-Driven**: CI pipelines run automatically in response to repository events such as commits or pull requests, removing reliance on human initiation.

* **Automation Enforces Standards**: Build steps, tests, and checks are executed the same way every time, ensuring predictable outcomes regardless of who made the change.

* **Fast Feedback Prevents Drift**: Immediate pipeline results help teams detect issues early, before changes are merged or released downstream.

## Required Tools

Before beginning this lab, ensure you have the necessary tools to build and observe a CI pipeline. These tools allow you to author workflows, trigger pipeline runs, and review execution results.

| Requirement                 | Description                                                                                       |
| :-------------------------- | :------------------------------------------------------------------------------------------------ |
| **Git Installed**           | Install from [git-scm.com/downloads](https://git-scm.com/downloads)                               |
| **GitHub Account**          | Create one at [github.com/join](https://github.com/join).                                         |
| **Visual Studio Code**      | Install from <br>[https://code.visualstudio.com/download](https://code.visualstudio.com/download) |
| **GitHub Actions Access**   | Enabled by default for public repositories                                                        |
| **YAML Support in VS Code** | Included by default                                                                               |

These tools should already be installed from previous labs. If your environment is ready, proceed to the hands-on steps to build your first CI pipeline.

## Lab Report

* Open a terminal in VS Code and record the output and observations from this exercise in a file named: `CSDO1010_LAB_05_REPORT_LASTNAME_FIRSTNAME`

* For each step, explain what the pipeline is doing, why it runs automatically, and how it supports safe infrastructure delivery.

* When complete, submit the report via Moodle.