import { ComponentFixture, TestBed } from '@angular/core/testing';

import { DetectorComponent } from './detector-component';

describe('DetectorComponent', () => {
  let component: DetectorComponent;
  let fixture: ComponentFixture<DetectorComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DetectorComponent]
    })
    .compileComponents();

    fixture = TestBed.createComponent(DetectorComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
