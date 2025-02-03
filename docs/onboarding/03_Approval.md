## STEP 3: Verify and Approve Registration Process

This step invloves approval process of a company. It is performed by the dataspace operator

- Login using CX-Operator company and credentials:

![Company Selection Page](./media/invitation/company-page.png)
    
- Go to the “Application Requests” from the Menu

![Portal Dashboard](./media/approval/portal-dashboard.png)

- In the Admin Board, you see the application requests from the participants

![Application Requests Page](./media/approval/application-requests-page.png)

- Go to the “Data Validation” check and approve it

![Data Validation Check](./media/approval/data-validation.png)

After approval, it must be green

![Data Validation Check Green](./media/approval/data-validation-2.png)

- Click on pencil symbol and add BPN number manually.
Example: **BPNL000000000CGI**

![Add BPN manually](./media/approval/add-bpn.png)

![Add BPN ](./media/approval/add-bpn-2.png)

![Checklist Status](./media/approval/checklist-status.png)

- Wait for some seconds until you see all three checks are passed: Data Validation, BPN Creation and Identity Wallet checks. Check by refreshing your page.

![BPN Creation Check ](./media/approval/checklist-status-2.png)

![Wallet Creation Check](./media/approval/checklist-status-3.png)

Since Clearing House and Self Description components are external components, there is currently no ways to get systematic approval from these components. The community is working on a toggle to disable the calls to these components. Currently, there is a workaround to bypass these checks using the SQL queries to be executed in the backend database (See below section Technical Steps to bypass external components).

If all checks are passed and registration is approved, the company admin will be notified via email


See [technical steps](./04_Technical_Steps.md) to skip the external components



